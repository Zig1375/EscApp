import Foundation

/// The list of runtimes EscApp can install. A runtime is a set of components (Wine, DXVK, DXMT) that were
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
    /// RPG Maker's Run Time Packages, which games made with it need (`RPGMakerGame`). Optional like `games`.
    public var rtps: [RTP]?
    /// Microsoft's runtimes that games are built against and Wine only imitates: Visual C++ and .NET. Optional
    /// like `games`.
    public var redists: [Redist]?

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
        /// The folder inside the archive that gets installed; empty for the whole archive. Lets EscApp take only
        /// `Wine Staging.app/Contents/Resources/wine` from Gcenx's app bundle.
        public var from: String
        /// Where that folder goes, relative to the runtime folder. It must not exist yet, so later components
        /// can't overwrite earlier ones (Wine Mono goes inside Wine's tree after Wine is in place).
        public var into: String
        /// What this build can do beyond plain Wine, for the app to switch on: `osync` (`WineEnvironment`),
        /// `d3dmetal` (`BackendTree.supportsD3DMetal`).
        /// Optional, so older manifests and older apps both still read the list.
        public var features: [String]?
    }

    /// One Run Time Package: the publisher's own installer, from the publisher's own server. Its license allows
    /// no redistribution, so it can't be repackaged on GitHub like the runtimes; `RTPInstaller` runs the
    /// installer once, silently, and keeps what it installed.
    public struct RTP: Codable, Sendable, Equatable {
        /// `RGSS`, `RGSS2` or `RGSS3` (`RPGMakerGame.Engine`). A string, so an engine this app doesn't know is
        /// skipped instead of making the manifest unreadable.
        public var engine: String
        /// What games call it in `Game.ini`: `Standard`, `RPGVX`, `RPGVXAce`.
        public var name: String
        public var version: String
        public var url: URL
        /// Lowercase hex.
        public var sha256: String
        public var size: Int64
        /// Shown in the app's licenses screen.
        public var license: String
        /// The installer inside the downloaded zip; empty when the download is the installer itself.
        public var setup: String

        public var engineValue: RPGMakerGame.Engine? { RPGMakerGame.Engine(rawValue: engine) }
    }

    /// One of Microsoft's redistributable runtimes, as Microsoft publishes it on its own servers. `RedistInstaller`
    /// runs the installer silently in a game's bottle when `RedistNeeds` finds the game built against it.
    public struct Redist: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// Visual C++: `provides` lists its DLLs.
            case vcrun
            /// .NET: `provides` lists its shared frameworks by major version, `Microsoft.NETCore.App/8`.
            case dotnet
        }

        /// Names it in a bottle's marker; a plain path component, `vcrun2010-x86`.
        public var id: String
        /// Shown while it installs: "Microsoft Visual C++ 2010".
        public var name: String
        /// A string, so a kind this app doesn't know is skipped instead of making the manifest unreadable.
        public var kind: String
        public var version: String
        /// `x86` or `x64`: the programs it serves. A 32-bit game needs the 32-bit runtime even on 64-bit Windows.
        public var architecture: String
        public var url: URL
        /// Lowercase hex.
        public var sha256: String
        public var size: Int64
        public var license: String
        /// The installer's switches for no window, no questions and no restart.
        public var arguments: [String]
        /// What a game asks for when it needs this runtime (see `Kind`), lowercased for Visual C++.
        public var provides: [String]
        /// Relative to `drive_c`: the folder that has it once it is installed. Visual C++ is installed when this
        /// folder (or one inside it, for `winsxs`) has Microsoft's own copy of the first DLL in `provides`;
        /// Wine's stand-ins are in `system32` from the start.
        public var check: String

        public var kindValue: Kind? { Kind(rawValue: kind) }
    }

    /// The package a game names, for its engine.
    public func rtp(_ name: String, engine: RPGMakerGame.Engine) -> RTP? {
        rtps?.first { $0.engineValue == engine && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public static func decode(_ data: Data) throws -> RuntimeManifest {
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        guard manifest.format <= supportedFormat else { throw ManifestError.newerFormat(manifest.format) }
        try manifest.validate()
        return manifest
    }

    /// The manifest that ships with this build of EscApp.
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
                try Self.checkPin(component, label: label)
                guard Self.isSafeRelativePath(component.into, allowEmpty: false),
                      Self.isSafeRelativePath(component.from, allowEmpty: true)
                else { throw ManifestError.invalidEntry("\(label): from or into") }
            }
        }
        for rtp in rtps ?? [] {
            let label = "rtp \(rtp.engine)/\(rtp.name)"
            try Self.checkPin(rtp, label: label)
            // Both name folders on disk; `setup` is a path inside the archive.
            guard Self.isSafeComponent(rtp.engine), Self.isSafeComponent(rtp.name),
                  Self.isSafeRelativePath(rtp.setup, allowEmpty: true)
            else { throw ManifestError.invalidEntry("\(label): engine, name or setup") }
        }
        try Self.validateRedists(redists ?? [])
    }

    private static func validateRedists(_ redists: [Redist]) throws {
        var seen = Set<String>()
        for redist in redists {
            let label = "redist \(redist.id)"
            try Self.checkPin(redist, label: label)
            guard Self.isSafeComponent(redist.id), seen.insert(redist.id).inserted,
                  Self.isSafeRelativePath(redist.check, allowEmpty: false), !redist.provides.isEmpty
            else { throw ManifestError.invalidEntry("\(label): id, check or provides") }
        }
    }

    private static func checkPin(_ download: some PinnedDownload, label: String) throws {
        guard download.url.scheme == "https" || download.url.isFileURL else {
            throw ManifestError.invalidEntry("\(label): only https downloads are allowed")
        }
        guard download.sha256.count == 64, download.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw ManifestError.invalidEntry("\(label): sha256") }
        guard download.size > 0 else { throw ManifestError.invalidEntry("\(label): size") }
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

extension RuntimeManifest.Runtime {
    /// Whether the runtime's Wine has `feature`.
    public func wineHas(_ feature: String) -> Bool {
        components.contains { $0.kind == .wine && $0.features?.contains(feature) == true }
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case newerFormat(Int)
    case invalidEntry(String)
    case missingBundledManifest

    public var description: String {
        switch self {
        case let .newerFormat(format): "The component list needs a newer EscApp (format \(format))."
        case let .invalidEntry(what): "The component list has a broken entry: \(what)."
        case .missingBundledManifest: "This copy of EscApp is missing its component list. Please reinstall EscApp."
        }
    }
}
