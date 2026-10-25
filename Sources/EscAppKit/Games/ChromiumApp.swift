import Foundation

/// Programs built on Chromium: NW.js games (RPG Maker MV and MZ ship as one), Electron apps and launchers, and
/// programs embedding CEF. In Wine on a Mac their window stays white or black: Chromium draws in a separate GPU
/// process, and what that process draws never reaches the window the Mac shows. With the GPU work inside the
/// browser process the picture appears and stays hardware-accelerated (WebGL games keep their speed); without
/// any GPU work is the fallback. Tested with NW.js 0.92 and Electron 33 on Wine 11.20.
///
/// Chromium also can't read the graphics driver's version under Wine, and older builds then put the GPU on their
/// blocklist and draw in software. RPG Maker MZ asks WebGL for real hardware only, so Celina's Calling (NW.js 0.48)
/// showed "Failed to initialize graphics" until the blocklist was switched off.
public enum ChromiumApp {
    public enum Mode: String, Codable, Sendable, Equatable {
        /// `--in-process-gpu`: the fix, with acceleration, and the GPU blocklist off (it is
        /// `--ignore-gpu-blacklist` up to Chromium 85 and `--ignore-gpu-blocklist` since; each ignores the other).
        case inProcessGPU
        /// Software drawing: for a program the first doesn't fix.
        case noGPU

        public var arguments: [String] {
            switch self {
            case .inProcessGPU: ["--in-process-gpu", "--ignore-gpu-blacklist", "--ignore-gpu-blocklist"]
            case .noGPU: ["--disable-gpu", "--disable-gpu-compositing", "--in-process-gpu"]
            }
        }

        /// What to try after this one; nil when nothing is left.
        public var next: Mode? { self == .inProcessGPU ? .noGPU : nil }

        /// The switches for the program in `folder`, with V8's flags (`jsFlags`) joined to any it sets itself.
        public func arguments(forProgramIn folder: URL) -> [String] {
            let package = try? Data(contentsOf: folder.appending(path: "package.json"))
            return arguments + ["--js-flags=" + ChromiumApp.jsFlags(packageJSON: package)]
        }
    }

    /// V8 flags every Chromium program gets.
    ///
    /// V8 (Chromium 106 and later) makes its own flags read-only once it has started and checks that the page
    /// was read-write before. Under Wine the page of a DLL's data doesn't report that, so the check fails and the
    /// program quits at once: "Inquisitor White Prison" (RPG Maker MZ, NW.js 0.69) showed no window, its log
    /// saying `Check failed: 0x04 == old_protection`. Older V8 doesn't know the flag and goes on without it.
    static let v8Flags = "--no-freeze-flags-after-init"

    /// The value for `--js-flags`: V8's flags an NW.js game sets in its `package.json` (`js-flags`, as RPG Maker MV
    /// writes `--expose-gc`, and any in `chromium-args`), then `v8Flags`. The command line's would otherwise replace
    /// the game's instead of adding to them.
    static func jsFlags(packageJSON: Data?) -> String {
        guard let data = packageJSON,
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return v8Flags }
        var flags = (package["js-flags"] as? String).map { [$0] } ?? []
        if let switches = package["chromium-args"] as? String,
           let match = switches.firstMatch(of: /--js-flags=(?:"([^"]*)"|'([^']*)'|(\S+))/) {
            flags.append(String(match.1 ?? match.2 ?? match.3 ?? ""))
        }
        return (flags + [v8Flags]).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
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
