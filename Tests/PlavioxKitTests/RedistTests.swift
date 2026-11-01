import Foundation
@testable import PlavioxKit
import Testing

private func redist(_ id: String, kind: String = "vcrun", architecture: String = "x64",
                    provides: [String], check: String = "windows/system32") -> RuntimeManifest.Redist {
    RuntimeManifest.Redist(id: id, name: id, kind: kind, version: "1", architecture: architecture,
                           // swiftlint:disable:next force_unwrapping
                           url: URL(string: "https://download.microsoft.com/\(id).exe")!,
                           sha256: String(repeating: "a", count: 64), size: 1, license: "MIT", arguments: ["/q"],
                           provides: provides, check: check)
}

private let vc2010 = [redist("vcrun2010-x86", architecture: "x86", provides: ["msvcr100.dll", "msvcp100.dll"]),
                      redist("vcrun2010-x64", provides: ["msvcr100.dll", "msvcp100.dll"])]
private let vc14 = redist("vcrun14-x64", provides: ["vcruntime140.dll", "msvcp140.dll"])
private let dotnet8 = redist("dotnet8-x64", kind: "dotnet",
                             provides: ["Microsoft.NETCore.App/8", "Microsoft.WindowsDesktop.App/8"],
                             check: "Program Files/dotnet/shared/Microsoft.WindowsDesktop.App/8.0.33")

/// A MonoGame game on .NET 8, as `dotnet publish` writes its `runtimeconfig.json`.
private let net8 = Data("""
    {"runtimeOptions": {"tfm": "net8.0", "framework": {"name": "Microsoft.NETCore.App", "version": "8.0.0"}}}
    """.utf8)

private let probes = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/probes")

@Suite struct RedistNeedsTests {
    @Test func aVisualCPlusPlusImportCallsForItsRuntimeOfTheGamesBitness() {
        let evidence = RedistNeeds.Evidence(architecture: "x86", missing: ["x86": ["kernel32.dll", "msvcp100.dll"]])
        #expect(RedistNeeds.needed(evidence, from: vc2010 + [vc14]).map(\.id) == ["vcrun2010-x86"])
    }

    @Test func aHelperGetsTheRuntimeOfItsOwnBitness() {
        // Translator++: a 64-bit program needing nothing, with a 32-bit php.exe built with Visual C++ 2019.
        let x86 = redist("vcrun14-x86", architecture: "x86", provides: ["vcruntime140.dll", "msvcp140.dll"])
        let evidence = RedistNeeds.Evidence(architecture: "x64",
                                            missing: ["x64": ["kernel32.dll"], "x86": ["vcruntime140.dll"]])
        #expect(RedistNeeds.needed(evidence, from: [x86, vc14]).map(\.id) == ["vcrun14-x86"])
    }

    @Test func aGameCarryingTheDLLsItselfNeedsNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "redist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exe = folder.appending(path: "Game.exe")
        try Data().write(to: exe)
        try Data().write(to: folder.appending(path: "msvcp140.dll"))
        let info = ExecutableInfo(format: .pe64, imports: ["msvcp140.dll", "vcruntime140.dll"], productName: nil,
                                  icon: nil, dpiAware: false)
        // One DLL short is still the runtime: the game would stop on the other.
        let half = try #require(RedistNeeds.read(executable: exe, info: info))
        #expect(half.missing["x64"] == ["vcruntime140.dll"])
        try Data().write(to: folder.appending(path: "vcruntime140.dll"))
        let carried = try #require(RedistNeeds.read(executable: exe, info: info))
        #expect(RedistNeeds.needed(carried, from: [vc14]).isEmpty)
    }

    @Test func programsInFoldersBelowCountWithTheirOwnBitness() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "redist-\(UUID().uuidString)")
        let php = folder.appending(path: "php")
        try FileManager.default.createDirectory(at: php, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exe = folder.appending(path: "Tool.exe")
        try Data().write(to: exe)
        // A 32-bit program importing d3d9.dll, as the helper in its own folder.
        try FileManager.default.copyItem(at: probes.appending(path: "d3d9-x86.exe"), to: php.appending(path: "php.exe"))
        let info = ExecutableInfo(format: .pe64, imports: ["kernel32.dll"], productName: nil, icon: nil,
                                  dpiAware: false)
        let evidence = try #require(RedistNeeds.read(executable: exe, info: info))
        #expect(evidence.missing["x86"]?.contains("d3d9.dll") == true)
        #expect(evidence.missing["x64"] == ["kernel32.dll"])
        // The helper carrying the DLL in its folder needs nothing for it.
        try Data().write(to: php.appending(path: "d3d9.dll"))
        #expect(RedistNeeds.read(executable: exe, info: info)?.missing["x86"]?.contains("d3d9.dll") == false)
    }

    @Test func aDotNetProgramGetsTheRuntimeOfItsMajorVersion() {
        let evidence = RedistNeeds.Evidence(architecture: "x64", frameworks: ["Microsoft.NETCore.App/8"])
        #expect(RedistNeeds.needed(evidence, from: [vc14, dotnet8]).map(\.id) == ["dotnet8-x64"])
        let older = RedistNeeds.Evidence(architecture: "x64", frameworks: ["Microsoft.NETCore.App/6"])
        #expect(RedistNeeds.needed(older, from: [dotnet8]).isEmpty)
    }

    @Test func aKindThisAppDoesNotKnowIsSkipped() {
        let future = redist("directx-x64", kind: "directx", provides: ["d3dx9_43.dll"])
        let evidence = RedistNeeds.Evidence(architecture: "x64", missing: ["x64": ["d3dx9_43.dll"]])
        #expect(RedistNeeds.needed(evidence, from: [future]).isEmpty)
    }

    @Test func runtimeConfigNamesItsFrameworks() {
        // A WinForms tool asks for two frameworks.
        #expect(RedistNeeds.frameworks(inRuntimeConfig: net8, files: []) == ["Microsoft.NETCore.App/8"])
        let tool = Data("""
            {"runtimeOptions": {"frameworks": [{"name": "Microsoft.NETCore.App", "version": "3.1.0"},
             {"name": "Microsoft.WindowsDesktop.App", "version": "3.1.0"}]}}
            """.utf8)
        #expect(RedistNeeds.frameworks(inRuntimeConfig: tool, files: [])
            == ["Microsoft.NETCore.App/3", "Microsoft.WindowsDesktop.App/3"])
    }

    @Test func aSelfContainedProgramAsksForNoRuntime() {
        let included = Data("""
            {"runtimeOptions": {"includedFrameworks": [{"name": "Microsoft.NETCore.App", "version": "8.0.1"}]}}
            """.utf8)
        #expect(RedistNeeds.frameworks(inRuntimeConfig: included, files: []).isEmpty)
        #expect(RedistNeeds.frameworks(inRuntimeConfig: net8, files: ["hostfxr.dll"]).isEmpty)
    }

    @Test func readsTheProgramsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "redist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exe = folder.appending(path: "Game.exe")
        try Data().write(to: exe)
        try net8.write(to: folder.appending(path: "Game.runtimeconfig.json"))
        let info = ExecutableInfo(format: .pe64, imports: ["msvcp140.dll"], productName: nil, icon: nil,
                                  dpiAware: false)
        let evidence = try #require(RedistNeeds.read(executable: exe, info: info))
        #expect(evidence.architecture == "x64")
        #expect(evidence.frameworks == ["Microsoft.NETCore.App/8"])
        let dos = ExecutableInfo(format: .dos, imports: [], productName: nil, icon: nil, dpiAware: false)
        #expect(RedistNeeds.read(executable: exe, info: dos) == nil)
    }
}

@Suite struct RedistInstallerTests {
    func bottle() throws -> URL {
        let bottle = FileManager.default.temporaryDirectory.appending(path: "redist-bottle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bottle.appending(path: "drive_c/windows/system32"),
                                                withIntermediateDirectories: true)
        return bottle
    }

    /// A DLL as wineboot leaves it: a PE file whose DOS stub says it is Wine's.
    func dll(wine: Bool) -> Data {
        var data = Data("MZ".utf8) + Data(repeating: 0, count: 0x3E)
        data += Data((wine ? "Wine builtin DLL" : "This program cannot be run in DOS mode.").utf8)
        return data + Data(repeating: 0, count: 64)
    }

    @Test func winesOwnCopyDoesNotCountAsInstalled() throws {
        let bottle = try bottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let system = bottle.appending(path: "drive_c/windows/system32")
        #expect(!RedistInstaller.isInstalled(vc14, in: bottle))
        try dll(wine: true).write(to: system.appending(path: "vcruntime140.dll"))
        #expect(!RedistInstaller.isInstalled(vc14, in: bottle))
        try dll(wine: false).write(to: system.appending(path: "vcruntime140.dll"))
        #expect(RedistInstaller.isInstalled(vc14, in: bottle))
    }

    @Test func sideBySideAssembliesCountForTheirOwnBitness() throws {
        let bottle = try bottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let x86 = redist("vcrun2008-x86", architecture: "x86", provides: ["msvcr90.dll"], check: "windows/winsxs")
        let x64 = redist("vcrun2008-x64", provides: ["msvcr90.dll"], check: "windows/winsxs")
        let assembly = bottle.appending(path: "drive_c/windows/winsxs/amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_9.0")
        try FileManager.default.createDirectory(at: assembly, withIntermediateDirectories: true)
        try dll(wine: false).write(to: assembly.appending(path: "msvcr90.dll"))
        #expect(RedistInstaller.isInstalled(x64, in: bottle))
        #expect(!RedistInstaller.isInstalled(x86, in: bottle))
    }

    @Test func winesCopiesStepAsideAndComeBackWhenNothingReplacedThem() throws {
        let bottle = try bottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let system = bottle.appending(path: "drive_c/windows/system32")
        let runtime = system.appending(path: "vcruntime140.dll"), cpp = system.appending(path: "msvcp140.dll")
        try dll(wine: true).write(to: runtime)
        try dll(wine: true).write(to: cpp)
        let aside = RedistInstaller.setAsideStandIns(of: vc14, in: bottle)
        #expect(Set(aside) == [runtime, cpp])
        #expect(!FileManager.default.fileExists(atPath: runtime.path))
        // The installer put down only one of them.
        try dll(wine: false).write(to: runtime)
        RedistInstaller.restore(aside)
        #expect(!RedistInstaller.isWineStandIn(runtime))
        #expect(RedistInstaller.isWineStandIn(cpp))
        #expect(try FileManager.default.contentsOfDirectory(atPath: system.path).sorted()
            == ["msvcp140.dll", "vcruntime140.dll"])
    }

    @Test func winesSideBySideAssemblyStepsAsideWithItsManifest() throws {
        let bottle = try bottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let x86 = redist("vcrun2008-x86", architecture: "x86", provides: ["msvcr90.dll", "msvcp90.dll"],
                         check: "windows/winsxs")
        let winsxs = bottle.appending(path: "drive_c/windows/winsxs")
        let name = "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_9.0.30729.6161_none_deadbeef"
        let assembly = winsxs.appending(path: name), manifest = winsxs.appending(path: "manifests/\(name).manifest")
        try FileManager.default.createDirectory(at: assembly, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try dll(wine: true).write(to: assembly.appending(path: "msvcr90.dll"))
        try dll(wine: true).write(to: assembly.appending(path: "msvcp90.dll"))
        try Data("<assembly/>".utf8).write(to: manifest)
        let aside = RedistInstaller.setAsideStandIns(of: x86, in: bottle)
        #expect(aside.map(\.path) == [assembly.path, manifest.path])
        #expect(!FileManager.default.fileExists(atPath: assembly.path))
        // The installer failed: Wine's assembly comes back as it was.
        RedistInstaller.restore(aside)
        #expect(RedistInstaller.isWineStandIn(assembly.appending(path: "msvcr90.dll")))
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test func dotNetIsInstalledWhenItsFrameworkFolderIsThere() throws {
        let bottle = try bottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        #expect(!RedistInstaller.isInstalled(dotnet8, in: bottle))
        try FileManager.default.createDirectory(at: bottle.appending(path: "drive_c").appending(path: dotnet8.check),
                                                withIntermediateDirectories: true)
        #expect(RedistInstaller.isInstalled(dotnet8, in: bottle))
    }

    @Test func aFailedDownloadIsRememberedUntilTheManifestHasAnother() throws {
        let bottle = try bottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        try RedistInstaller.record(vc14, installed: false, in: bottle)
        #expect(RedistInstaller.failedBefore(vc14, in: bottle))
        var newer = vc14
        newer.sha256 = String(repeating: "b", count: 64)
        #expect(!RedistInstaller.failedBefore(newer, in: bottle))
        try RedistInstaller.record(vc14, installed: true, in: bottle)
        #expect(!RedistInstaller.failedBefore(vc14, in: bottle))
        #expect(RedistInstaller.marker(in: bottle).installed.map(\.id) == ["vcrun14-x64"])
    }
}

@Suite struct RedistManifestTests {
    @Test func bundledRuntimesComeFromMicrosoftForBothBitnesses() throws {
        let manifest = try RuntimeManifest.bundled()
        try ManifestUpdater.validateRemote(manifest)
        let redists = try #require(manifest.redists)
        #expect(redists.allSatisfy { $0.kindValue != nil })
        for id in ["vcrun2005", "vcrun2010", "vcrun14", "dotnet8", "dotnet10"] {
            #expect(redists.contains { $0.id == "\(id)-x86" } && redists.contains { $0.id == "\(id)-x64" })
        }
    }

    @Test func otherHostsAreRejected() throws {
        var manifest = try RuntimeManifest.bundled()
        // swiftlint:disable:next force_unwrapping
        manifest.redists?[0].url = URL(string: "https://example.com/vcredist_x86.exe")!
        #expect(throws: ManifestError.self) { try ManifestUpdater.validateRemote(manifest) }
    }

    @Test func aCachedListFromBeforeRuntimesTakesTheAppsOnes() throws {
        let bundled = try RuntimeManifest.bundled()
        var cached = bundled
        cached.redists = nil
        #expect(ManifestUpdater.choose(bundled: bundled, cached: cached).redists == bundled.redists)
    }
}
