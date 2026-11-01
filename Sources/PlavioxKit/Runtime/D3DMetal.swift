import Foundation

/// Apple's D3DMetal, which runs Direct3D 12 games: taken from the player's own download of Apple's "Evaluation
/// environment for Windows games" (a disk image from developer.apple.com, free with an Apple Account).
///
/// Plaviox never ships, downloads or changes it. Apple's license lets D3DMetal be passed on only for non-commercial
/// purposes, so the player gets it from Apple under that license, and Plaviox copies the image's `redist/lib`
/// as it is, after checking Apple's signature, into `Plaviox/D3DMetal/<version>` with a `D3DMETAL.json` marker
/// written last, like a runtime (`RuntimeInstaller`).
public enum D3DMetal {
    public static let markerName = "D3DMETAL.json"

    public struct Installed: Codable, Sendable, Equatable {
        /// `CFBundleShortVersionString` of `D3DMetal.framework`: "3.0", "4.0b3".
        public var version: String
        /// The disk image it came from, for the setup screen.
        public var source: String
    }

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        /// The image has no D3DMetal: another download from Apple's page, or not Apple's at all.
        case notD3DMetal
        /// D3DMetal is there but not signed by Apple: damaged, or changed by someone.
        case notSignedByApple(String)
        case cantAttach(String)

        public var description: String {
            switch self {
            case .notD3DMetal: "The disk image doesn't contain D3DMetal."
            case let .notSignedByApple(file): "\(file) isn't signed by Apple."
            case let .cantAttach(name): "Can't open the disk image \(name)."
            }
        }
    }

    /// Paths inside `redist/lib` that a working D3DMetal needs. Everything else in the folder is copied too.
    static let requiredFiles = [
        "external/D3DMetal.framework", "external/libd3dshared.dylib",
        "wine/x86_64-windows/d3d12.dll", "wine/x86_64-windows/dxgi.dll",
        "wine/x86_64-unix/d3d12.so", "wine/x86_64-unix/dxgi.so",
    ]
    static let infoPlist = "external/D3DMetal.framework/Resources/Info.plist"
    /// What `codesign` checks against Apple's anchor; the `.so` files are links to `libd3dshared.dylib`.
    static let signedFiles = ["external/D3DMetal.framework", "external/libd3dshared.dylib"]

    /// The folder in a disk image (paths relative to its root) that holds D3DMetal: `redist/lib` in 3.0 and
    /// 4.0 beta 3. Found by its contents, so a later image that moves it still works.
    static func libFolder(in entries: Set<String>) -> String? {
        let anchor = "external/D3DMetal.framework"
        let candidates = entries.filter { $0 == anchor || $0.hasSuffix("/" + anchor) }
            .map { String($0.dropLast(anchor.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .sorted { $0.count < $1.count }
        return candidates.first { folder in
            requiredFiles.allSatisfy { entries.contains(folder.isEmpty ? $0 : folder + "/" + $0) }
        }
    }

    /// The framework's version from its `Info.plist`.
    static func version(infoPlist: Data) -> String? {
        let plist = try? PropertyListSerialization.propertyList(from: infoPlist, format: nil) as? [String: Any]
        return (plist?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether Direct3D 12 games can run: D3DMetal is added and `runtime`'s Wine can load it.
    public static func isReady(paths: AppPaths, runtime: RuntimeManifest.Runtime) -> Bool {
        guard installed(paths: paths) != nil,
              let folder = RuntimeInstaller(paths: paths).installed(runtime) else { return false }
        return BackendTree.supportsD3DMetal(runtimeFolder: folder)
    }

    /// The installed D3DMetal with its folder. There is only ever one: an import replaces the one before.
    public static func installed(paths: AppPaths) -> (folder: URL, info: Installed)? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: paths.d3dmetal,
                                                                    includingPropertiesForKeys: nil)) ?? []
        return entries.lazy.compactMap { folder -> (URL, Installed)? in
            guard let data = try? Data(contentsOf: folder.appending(path: markerName)),
                  let info = try? JSONDecoder().decode(Installed.self, from: data) else { return nil }
            return (folder, info)
        }.first
    }
}

/// One D3DMetal taken from a disk image and checked, waiting in a staging folder for the player to accept
/// Apple's license (`license`, the image's own `License.rtf`). `install` moves it into place; `discard` drops it.
public struct D3DMetalCandidate: Sendable, Equatable {
    public var version: String
    public var source: String
    public var license: URL
    let staging: URL
}

extension D3DMetal {
    /// Opens `image`, finds D3DMetal, checks Apple's signature and copies it to a staging folder. Nothing is
    /// installed yet.
    public static func prepare(image: URL, paths: AppPaths) async throws -> D3DMetalCandidate {
        let disc: MountedDisc
        do { disc = try await DiscImage.attach(image, paths: paths) } catch {
            throw ImportError.cantAttach(image.lastPathComponent)
        }
        do {
            let candidate = try await copy(from: disc.mountPoint, image: image, paths: paths)
            await DiscImage.detach(disc)
            return candidate
        } catch {
            await DiscImage.detach(disc)
            throw error
        }
    }

    private static func copy(from root: URL, image: URL, paths: AppPaths) async throws -> D3DMetalCandidate {
        guard let folder = libFolder(in: relativeFiles(under: root)) else { throw ImportError.notD3DMetal }
        let lib = folder.isEmpty ? root : root.appending(path: folder, directoryHint: .isDirectory)
        try await checkSignatures(in: lib)

        try FileManager.default.createDirectory(at: paths.d3dmetal, withIntermediateDirectories: true)
        let staging = paths.d3dmetal.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            // ditto keeps the links between the .so files and libd3dshared.dylib, and the framework's own links.
            let copy = staging.appending(path: "lib", directoryHint: .isDirectory)
            try await ProcessRunner.check("/usr/bin/ditto", [lib.path(percentEncoded: false),
                                                             copy.path(percentEncoded: false)])
            // Apple's notices (License.rtf, Acknowledgements.rtf at the image's top) go with every copy.
            for name in ["License.rtf", "Acknowledgements.rtf"] {
                let file = root.appending(path: name)
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.copyItem(at: file, to: staging.appending(path: name))
                }
            }
            // Checked again in the copy, which is what games will load.
            try await checkSignatures(in: staging.appending(path: "lib"))
            let plist = try Data(contentsOf: staging.appending(path: "lib/" + infoPlist))
            guard let version = version(infoPlist: plist) else { throw ImportError.notD3DMetal }
            return D3DMetalCandidate(version: version, source: image.lastPathComponent,
                                     license: staging.appending(path: "License.rtf"), staging: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Moves a prepared D3DMetal into place, after the player accepted Apple's license.
    public static func install(_ candidate: D3DMetalCandidate, paths: AppPaths) throws {
        let fileManager = FileManager.default
        let marker = try JSONEncoder().encode(Installed(version: candidate.version, source: candidate.source))
        try marker.write(to: candidate.staging.appending(path: markerName))
        // One D3DMetal at a time: a newer or older download replaces the one before. A game running on the old
        // one keeps what it loaded.
        for old in (try? fileManager.contentsOfDirectory(at: paths.d3dmetal, includingPropertiesForKeys: nil)) ?? []
        where !old.lastPathComponent.hasPrefix(".") {
            try fileManager.removeItem(at: old)
        }
        try fileManager.moveItem(at: candidate.staging,
                                 to: paths.d3dmetal.appending(path: candidate.version, directoryHint: .isDirectory))
        BackendTree.removeStaleD3DMetalTrees(paths: paths, keeping: candidate.version)
    }

    public static func discard(_ candidate: D3DMetalCandidate) {
        try? FileManager.default.removeItem(at: candidate.staging)
    }

    /// Removes every installed D3DMetal and what an import left behind.
    public static func remove(paths: AppPaths) throws {
        BackendTree.removeStaleD3DMetalTrees(paths: paths, keeping: nil)
        guard FileManager.default.fileExists(atPath: paths.d3dmetal.path) else { return }
        try FileManager.default.removeItem(at: paths.d3dmetal)
    }

    /// Every file, folder and link in the image by its own path; links aren't followed, so the framework's
    /// `Resources` link is listed but not what is inside it.
    static func relativeFiles(under root: URL) -> Set<String> {
        Set((try? FileManager.default.subpathsOfDirectory(atPath: root.path(percentEncoded: false))) ?? [])
    }

    static func checkSignatures(in lib: URL) async throws {
        for file in signedFiles {
            let result = try await ProcessRunner.run("/usr/bin/codesign", [
                "--verify", "--strict", "-R=anchor apple", lib.appending(path: file).path(percentEncoded: false),
            ])
            guard result.status == 0 else { throw ImportError.notSignedByApple(URL(filePath: file).lastPathComponent) }
        }
    }
}
