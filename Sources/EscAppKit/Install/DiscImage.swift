import Foundation

/// A disc image attached to the Mac, for a game to see as its CD in drive `D:`.
///
/// `hdiutil` attaches it read-only and hidden from Finder. Wine needs two things to treat it as a real CD: the
/// drive marked `cdrom` in the registry, and `d::` linked to the image's device, from which it reads the disc's
/// label. Old games check the label to tell their CD is in (checked: without `d::` Wine reports no label).
public struct MountedDisc: Sendable, Equatable {
    public var image: URL
    public var mountPoint: URL
    /// `/dev/diskN`.
    public var device: String
    /// False when the image was already attached (double-clicked in Finder): EscApp then leaves it attached.
    public var attachedByEscApp: Bool
}

public enum DiscImage {
    /// Images EscApp opens: what `hdiutil` attaches, and raw CD images it converts first (`RawDisc`).
    public static let extensions = Set(["iso", "img", "cdr", "toast", "dmg"]).union(RawDisc.extensions)

    public static func isImage(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Attaches `image` under `EscApp/Discs`, or returns where it is already attached.
    public static func attach(_ image: URL, paths: AppPaths) async throws -> MountedDisc {
        // A BIN/CUE is attached as the ISO made from it; the game keeps the image it came on.
        let source = RawDisc.isRaw(image)
            ? try await Task.detached(priority: .userInitiated) { try RawDisc.iso(for: image, paths: paths) }.value
            : image
        if var attached = try await attached().first(where: { same($0.image, source) }) {
            attached.image = image
            return attached
        }
        let mountPoint = paths.root.appending(path: "Discs/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run("/usr/bin/hdiutil", [
            "attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-plist",
            "-mountpoint", mountPoint.path(percentEncoded: false), source.path(percentEncoded: false),
        ])
        guard result.status == 0, let device = parseAttach(plist(in: result.output)) else {
            try? FileManager.default.removeItem(at: mountPoint)
            throw DiscError.cantAttach(image.lastPathComponent)
        }
        return MountedDisc(image: image, mountPoint: mountPoint, device: device.device, attachedByEscApp: true)
    }

    /// Detaches a disc EscApp attached; one the player attached stays.
    public static func detach(_ disc: MountedDisc) async {
        guard disc.attachedByEscApp else { return }
        _ = try? await ProcessRunner.run("/usr/bin/hdiutil", ["detach", disc.device, "-force"])
        try? FileManager.default.removeItem(at: disc.mountPoint)
    }

    /// Detaches `image` if EscApp attached it (under `EscApp/Discs`), once its game has ended.
    public static func detach(image: URL, paths: AppPaths) async {
        let ours = paths.root.appending(path: "Discs").standardizedFileURL.path(percentEncoded: false)
        let source = RawDisc.isRaw(image) ? RawDisc.cachedISO(for: image, paths: paths) : image
        for disc in (try? await attached()) ?? [] where same(disc.image, source)
            && disc.mountPoint.standardizedFileURL.path(percentEncoded: false).hasPrefix(ours) {
            await detach(MountedDisc(image: disc.image, mountPoint: disc.mountPoint, device: disc.device,
                                     attachedByEscApp: true))
        }
    }

    /// Every attached disc image that has a mounted volume.
    public static func attached() async throws -> [MountedDisc] {
        let result = try await ProcessRunner.run("/usr/bin/hdiutil", ["info", "-plist"])
        return parseInfo(plist(in: result.output))
    }

    /// The plist part of `hdiutil`'s output. Newer macOS prints a deprecation warning first, and the runner
    /// hands back stderr together with stdout.
    static func plist(in output: String) -> Data {
        Data((output.range(of: "<?xml").map { String(output[$0.lowerBound...]) } ?? output).utf8)
    }

    /// Detaches what EscApp left attached under `EscApp/Discs`, after a crash or when EscApp quits.
    public static func detachAll(paths: AppPaths) async {
        let ours = paths.root.appending(path: "Discs").standardizedFileURL.path(percentEncoded: false)
        for disc in (try? await attached()) ?? []
        where disc.mountPoint.standardizedFileURL.path(percentEncoded: false).hasPrefix(ours) {
            await detach(MountedDisc(image: disc.image, mountPoint: disc.mountPoint, device: disc.device,
                                     attachedByEscApp: true))
        }
    }

    static func parseAttach(_ plist: Data) -> (device: String, mountPoint: String)? {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        return volume(in: entities)
    }

    static func parseInfo(_ plist: Data) -> [MountedDisc] {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]],
                  let volume = volume(in: entities) else { return nil }
            return MountedDisc(image: URL(filePath: path), mountPoint: URL(filePath: volume.mountPoint),
                               device: volume.device, attachedByEscApp: false)
        }
    }

    /// The whole-disk device (`/dev/disk14`, not a partition) and the mounted volume's folder.
    private static func volume(in entities: [[String: Any]]) -> (device: String, mountPoint: String)? {
        let devices = entities.compactMap { $0["dev-entry"] as? String }
        guard let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first,
              let whole = devices.min(by: { $0.count < $1.count }) else { return nil }
        return (whole, mountPoint)
    }

    private static func same(_ one: URL, _ other: URL) -> Bool {
        one.resolvingSymlinksInPath().standardizedFileURL == other.resolvingSymlinksInPath().standardizedFileURL
    }
}

/// Drive `D:` of a bottle: the CD drive.
public enum DiscDrive {
    public static let letter = "d"

    /// Puts the disc in the bottle's drive. Edits the registry as text, so only while the bottle's Wine is down.
    public static func insert(_ disc: MountedDisc, into bottle: URL) throws {
        let devices = bottle.appending(path: "dosdevices", directoryHint: .isDirectory)
        try link(devices.appending(path: "\(letter):"), to: disc.mountPoint.path(percentEncoded: false))
        // The raw device: Wine reads the label from it.
        let raw = disc.device.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        try link(devices.appending(path: "\(letter)::"), to: raw)
        try BottleManager.setRegistryString(bottle: bottle, key: #"Software\Wine\Drives"#, name: "\(letter):",
                                            value: "cdrom", file: "system.reg")
    }

    /// Empties the drive. The `cdrom` mark stays: an empty CD drive is what a game expects to find.
    public static func eject(from bottle: URL) {
        let devices = bottle.appending(path: "dosdevices", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: devices.appending(path: "\(letter):"))
        try? FileManager.default.removeItem(at: devices.appending(path: "\(letter)::"))
    }

    static func link(_ link: URL, to destination: String) throws {
        let fileManager = FileManager.default
        if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) == destination { return }
        try? fileManager.removeItem(at: link)
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }
}

public enum DiscError: Error, Equatable, CustomStringConvertible {
    case cantAttach(String)
    case missing(String)

    public var description: String {
        switch self {
        case let .cantAttach(name): "Couldn't open the disc image \(name)."
        case let .missing(path): "The game's disc image isn't at \(path) any more."
        }
    }
}
