import Foundation

/// Which of Microsoft's runtimes (`RuntimeManifest.Redist`) a game was built against and doesn't carry itself.
///
/// Wine has its own Visual C++ libraries, and Wine Mono stands in for the .NET Framework, but neither is the real
/// thing: a game built with Visual C++ can stop on a function Wine's copy lacks, and a program built on .NET 5 and
/// later doesn't run at all without Microsoft's runtime ("You must install .NET to run this application"). So the
/// game gets what Windows players get from the game's own prerequisites installer.
public struct RedistNeeds: Sendable, Equatable {
    /// What a game's folder tells, read by `read(executable:info:)`.
    public struct Evidence: Sendable, Equatable {
        /// The program's own: the .NET runtime it needs has its bitness.
        public var architecture: String
        /// Lowercased DLL names that programs in the folder import and don't carry, by the bitness of the program
        /// that imports them (`x86`, `x64`): a game that ships a runtime's DLLs loads those, like on Windows.
        public var missing: [String: Set<String>]
        /// The shared frameworks a .NET program asks for, as `Microsoft.NETCore.App/8`.
        public var frameworks: [String]

        public init(architecture: String, missing: [String: Set<String>] = [:], frameworks: [String] = []) {
            self.architecture = architecture
            self.missing = missing
            self.frameworks = frameworks
        }
    }

    /// The runtimes `evidence` calls for, in the manifest's order (older Visual C++ first, .NET last).
    public static func needed(_ evidence: Evidence,
                              from redists: [RuntimeManifest.Redist]) -> [RuntimeManifest.Redist] {
        redists.filter { redist in
            switch redist.kindValue {
            case .vcrun?:
                let missing = evidence.missing[redist.architecture] ?? []
                return redist.provides.contains { missing.contains($0) }
            case .dotnet?:
                return redist.architecture == evidence.architecture && redist.provides.contains { provided in
                    evidence.frameworks.contains { $0.caseInsensitiveCompare(provided) == .orderedSame }
                }
            case nil:
                return false
            }
        }
    }

    /// The architecture a program's runtimes must have; nil for what Wine can't run anyway.
    static func architecture(of format: ExecutableInfo.Format) -> String? {
        switch format {
        case .pe32: "x86"
        case .pe64: "x64"
        case .win16, .dos: nil
        }
    }

    /// How deep below the program's folder other programs and DLLs are read, and how many at most. Helpers in
    /// folders of their own need runtimes too: Translator++ is a 64-bit NW.js program that needs nothing, but
    /// its `php/php.exe` is 32-bit Visual C++ 2019 and refuses Wine's `vcruntime140.dll` ("2.47 is not
    /// compatible with this PHP build linked with 14.29"), so Translator++ couldn't open a game.
    static let depth = 2
    static let fileLimit = 256

    /// Reads the evidence from the program's folder; nil for a program Wine can't run.
    public static func read(executable: URL, info: ExecutableInfo) -> Evidence? {
        guard let architecture = architecture(of: info.format) else { return nil }
        let folder = executable.deletingLastPathComponent()
        let files = names(in: folder)
        var evidence = Evidence(architecture: architecture,
                                missing: [architecture: info.imports.subtracting(files)])
        let others = binaries(under: folder, excluding: executable.lastPathComponent.lowercased())
        for binary in others.prefix(fileLimit) {
            guard let other = try? ExecutableInfo.read(binary), let bitness = Self.architecture(of: other.format)
            else { continue }
            // Windows finds a DLL's own imports in the program's folder as well as in the DLL's.
            let carried = files.union(names(in: binary.deletingLastPathComponent()))
            evidence.missing[bitness, default: []].formUnion(other.imports.subtracting(carried))
        }
        let name = executable.deletingPathExtension().lastPathComponent
        let config = folder.appending(path: name + ".runtimeconfig.json")
        evidence.frameworks = (try? Data(contentsOf: config)).map { frameworks(inRuntimeConfig: $0, files: files) }
            ?? []
        return evidence
    }

    /// Lowercased names of the files in `folder`.
    private static func names(in folder: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
    }

    /// The `.exe` and `.dll` files in `folder` and the folders below it down to `depth`, nearest first.
    static func binaries(under folder: URL, excluding program: String) -> [URL] {
        let fileManager = FileManager.default
        var found: [URL] = []
        var level = [folder]
        for depth in 0...Self.depth {
            var next: [URL] = []
            for directory in level {
                let names = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
                for name in names where !name.hasPrefix(".") {
                    let item = directory.appending(path: name)
                    let lower = name.lowercased()
                    if lower.hasSuffix(".exe") || lower.hasSuffix(".dll") {
                        if !(depth == 0 && lower == program) { found.append(item) }
                    } else if depth < Self.depth, (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                        == true {
                        next.append(item)
                    }
                }
                if found.count >= fileLimit { return found }
            }
            level = next
        }
        return found
    }

    /// The shared frameworks a `<program>.runtimeconfig.json` asks for, as `Microsoft.WindowsDesktop.App/8`.
    /// A self-contained program (`includedFrameworks`, or `hostfxr.dll` beside it) carries its runtime and asks
    /// for none.
    static func frameworks(inRuntimeConfig data: Data, files: Set<String>) -> [String] {
        struct Config: Decodable {
            struct Options: Decodable {
                var framework: Framework?
                var frameworks: [Framework]?
            }
            struct Framework: Decodable {
                var name: String
                var version: String?
            }
            var runtimeOptions: Options?
        }
        guard !files.contains("hostfxr.dll"), let options = try? JSONDecoder().decode(Config.self, from: data)
            .runtimeOptions else { return [] }
        return ([options.framework].compactMap { $0 } + (options.frameworks ?? [])).compactMap { framework in
            guard let major = framework.version?.split(separator: ".").first, Int(major) != nil else { return nil }
            return "\(framework.name)/\(major)"
        }
    }
}
