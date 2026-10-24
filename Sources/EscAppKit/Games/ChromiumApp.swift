import Foundation

/// Programs built on Chromium: NW.js games (RPG Maker MV and MZ ship as one), Electron apps and launchers, and
/// programs embedding CEF. In Wine on a Mac their window stays white or black: Chromium draws in a separate GPU
/// process, and what that process draws never reaches the window the Mac shows. With the GPU work inside the
/// browser process the picture appears and stays hardware-accelerated (WebGL games keep their speed); without
/// any GPU work is the fallback. Tested with NW.js 0.92 and Electron 33 on Wine 11.20.
public enum ChromiumApp {
    public enum Mode: String, Codable, Sendable, Equatable {
        /// `--in-process-gpu`: the fix, with acceleration.
        case inProcessGPU
        /// Software drawing: for a program the first doesn't fix.
        case noGPU

        public var arguments: [String] {
            switch self {
            case .inProcessGPU: ["--in-process-gpu"]
            case .noGPU: ["--disable-gpu", "--disable-gpu-compositing", "--in-process-gpu"]
            }
        }

        /// What to try after this one; nil when nothing is left.
        public var next: Mode? { self == .inProcessGPU ? .noGPU : nil }
    }

    /// Whether the program at `executable` is a Chromium browser itself, from its imports and the files next to
    /// it. Its helper processes and Chromium in another folder (a launcher's web pages) don't count: flags reach
    /// Chromium only on its main program's command line.
    public static func isChromium(executable: URL, imports: Set<String>) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: executable.deletingLastPathComponent().path))
            ?? []
        return isChromium(imports: imports, filesBeside: Set(names.map { $0.lowercased() }))
    }

    static func isChromium(imports: Set<String>, filesBeside files: Set<String>) -> Bool {
        // NW.js: nw.exe (an RPG Maker game's Game.exe) loads nw_elf.dll, with nw.dll beside it.
        if imports.contains("nw_elf.dll") || imports.contains("nw.dll") { return true }
        // CEF: the program links libcef.dll itself.
        if imports.contains("libcef.dll") { return true }
        // Electron and other Chromium builds: Chromium's data files beside the program.
        let hasPak = files.contains { $0.hasSuffix(".pak") }
        let hasEngine = files.contains("libegl.dll") || files.contains("v8_context_snapshot.bin")
        return files.contains("icudtl.dat") && hasPak && hasEngine
    }

    /// A Chromium GPU process running in the bottle: the program is Chromium even if its files didn't say so (a
    /// launcher that unpacks it at start, say).
    public static func runsGPUProcess(in bottle: URL) -> Bool {
        WineProcesses.running(in: bottle).contains { $0.arguments.contains("--type=gpu-process") }
    }
}
