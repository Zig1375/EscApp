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
        public var architecture: String
        /// Lowercased DLL names the program imports, and the DLLs beside it of the same bitness.
        public var imports: Set<String>
        /// Lowercased names of the files in the program's folder: a DLL the game carries needs no runtime.
        public var files: Set<String>
        /// The shared frameworks a .NET program asks for, as `Microsoft.NETCore.App/8`.
        public var frameworks: [String]

        public init(architecture: String, imports: Set<String>, files: Set<String> = [], frameworks: [String] = []) {
            self.architecture = architecture
            self.imports = imports
            self.files = files
            self.frameworks = frameworks
        }
    }

    /// The runtimes `evidence` calls for, in the manifest's order (older Visual C++ first, .NET last).
    public static func needed(_ evidence: Evidence,
                              from redists: [RuntimeManifest.Redist]) -> [RuntimeManifest.Redist] {
        redists.filter { redist in
            guard redist.architecture == evidence.architecture else { return false }
            switch redist.kindValue {
            case .vcrun?:
                // A game that ships the runtime's DLLs beside it loads those, like on Windows.
                return redist.provides.contains { evidence.imports.contains($0) && !evidence.files.contains($0) }
            case .dotnet?:
                return redist.provides.contains { provided in
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

    /// At most this many DLLs beside the program are read: Visual C++ games keep their own DLLs next to the exe,
    /// and a folder of hundreds (a plugin directory) isn't worth reading on every launch.
    static let dllLimit = 64

    /// Reads the evidence from the program's folder; nil for a program Wine can't run.
    public static func read(executable: URL, info: ExecutableInfo) -> Evidence? {
        guard let architecture = architecture(of: info.format) else { return nil }
        let folder = executable.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let files = Set(names.map { $0.lowercased() })
        var imports = info.imports
        for name in names.filter({ $0.lowercased().hasSuffix(".dll") }).sorted().prefix(dllLimit) {
            guard let dll = try? ExecutableInfo.read(folder.appending(path: name)), dll.format == info.format else {
                continue
            }
            imports.formUnion(dll.imports)
        }
        let name = executable.deletingPathExtension().lastPathComponent
        let config = folder.appending(path: name + ".runtimeconfig.json")
        let frameworks = (try? Data(contentsOf: config)).map { frameworks(inRuntimeConfig: $0, files: files) } ?? []
        return Evidence(architecture: architecture, imports: imports, files: files, frameworks: frameworks)
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
