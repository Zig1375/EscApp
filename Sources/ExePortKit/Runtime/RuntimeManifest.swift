import Foundation

/// The list of runtimes ExePort can install. A runtime is a set of components (Wine, DXVK, DXMT) that were
/// tested together and are always installed together, so a game never runs on a mix nobody tried.
///
/// A copy ships inside the app, so a fresh Mac can install without asking any server what to trust. Every
/// download is checked against the SHA-256 written here before it is used.
public struct RuntimeManifest: Codable, Sendable, Equatable {
    /// Bumped only for changes older apps can't read. Older apps ignore a manifest with a newer format.
    public static let supportedFormat = 1

    public var format: Int
    /// Oldest first. New runtimes are appended, so the last usable one is the newest.
    public var runtimes: [Runtime]
    /// The game database: settings known to work for particular games. Optional, so manifests without it and
    /// older apps reading one with it both still work.
    public var games: [KnownGame]?

    public struct Runtime: Codable, Sendable, Equatable, Identifiable {
        /// Names the runtime folder and template bottle, so it must be a plain path component.
        public var id: String
        public var minApp: Version
        public var minMacOS: Version
        public var components: [Component]
    }

    public struct Component: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case wine, dxvk, dxmt
            /// Only for a Wine build that doesn't carry Wine Mono itself (Gcenx's builds do).
            case mono
        }

        public var kind: Kind
        public var version: String
        public var url: URL
        /// Lowercase hex.
        public var sha256: String
        public var size: Int64
        /// SPDX identifier, shown in the app's licenses screen.
        public var license: String
        /// The folder inside the archive that gets installed; empty for the whole archive. Lets ExePort take only
        /// `Wine Staging.app/Contents/Resources/wine` from Gcenx's app bundle.
        public var from: String
        /// Where that folder goes, relative to the runtime folder. It must not exist yet, so later components
        /// can't overwrite earlier ones (Wine Mono goes inside Wine's tree after Wine is in place).
        public var into: String
    }

    public static func decode(_ data: Data) throws -> RuntimeManifest {
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        guard manifest.format <= supportedFormat else { throw ManifestError.newerFormat(manifest.format) }
        try manifest.validate()
        return manifest
    }

    /// The manifest that ships with this build of ExePort.
    public static func bundled() throws -> RuntimeManifest {
        guard let url = Bundle.module.url(forResource: "runtime-manifest", withExtension: "json") else {
            throw ManifestError.missingBundledManifest
        }
        return try decode(Data(contentsOf: url))
    }

    /// The newest runtime this app and this macOS can use.
    public func newest(forApp app: Version, macOS: Version) -> Runtime? {
        runtimes.last { $0.minApp <= app && $0.minMacOS <= macOS }
    }

    /// The manifest decides folder names and unpack locations, so a bad entry must fail here, before anything
    /// touches the disk, rather than unpack outside the runtime folder.
    func validate() throws {
        var seen = Set<String>()
        for runtime in runtimes {
            guard Self.isSafeComponent(runtime.id), seen.insert(runtime.id).inserted else {
                throw ManifestError.invalidEntry("runtime id \(runtime.id)")
            }
            for component in runtime.components {
                let label = "\(runtime.id)/\(component.kind.rawValue)"
                guard component.url.scheme == "https" || component.url.isFileURL else {
                    throw ManifestError.invalidEntry("\(label): only https downloads are allowed")
                }
                guard component.sha256.count == 64,
                      component.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
                else { throw ManifestError.invalidEntry("\(label): sha256") }
                guard component.size > 0 else { throw ManifestError.invalidEntry("\(label): size") }
                guard Self.isSafeRelativePath(component.into, allowEmpty: false),
                      Self.isSafeRelativePath(component.from, allowEmpty: true)
                else { throw ManifestError.invalidEntry("\(label): from or into") }
            }
        }
    }

    private static func isSafeRelativePath(_ path: String, allowEmpty: Bool) -> Bool {
        if path.isEmpty { return allowEmpty }
        return !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { isSafeComponent(String($0)) }
    }

    private static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") && !name.contains("/")
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case newerFormat(Int)
    case invalidEntry(String)
    case missingBundledManifest

    public var description: String {
        switch self {
        case let .newerFormat(format): "The component list needs a newer ExePort (format \(format))."
        case let .invalidEntry(what): "The component list has a broken entry: \(what)."
        case .missingBundledManifest: "This copy of ExePort is missing its component list. Please reinstall ExePort."
        }
    }
}
