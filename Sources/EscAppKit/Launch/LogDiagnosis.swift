import Foundation

/// What a game's log says went wrong, read from patterns seen in real runs. Pure text matching, so it is tested
/// without Wine. It decides one thing the retry loop needs: whether another graphics backend could help.
public struct LogDiagnosis: Sendable, Equatable {
    public enum Problem: Sendable, Equatable {
        /// A file the game itself loads isn't there: the game isn't fully installed (a missing `binkw32.dll`).
        case missingFile(String)
        /// The graphics backend couldn't give the game a device, or its own files didn't load.
        case graphics
        case directX12
        /// Anti-cheat that needs Windows itself.
        case antiCheat(String)
        /// Windows reported a crash (a page fault or an unhandled exception).
        case crash
    }

    public var problem: Problem?
    /// The log line that matched.
    public var evidence: String?
    /// Error lines worth putting in a report, without the noise in between.
    public var excerpt: [String]

    /// Whether another backend could fix it. A missing game file or anti-cheat fails the same way on every backend.
    public var retryHelps: Bool { Self.retryHelps(problem) }

    public static func retryHelps(_ problem: Problem?) -> Bool {
        switch problem {
        case .missingFile, .antiCheat, .directX12: false
        case .graphics, .crash, nil: true
        }
    }

    /// DLLs that come with the graphics backend (or Wine) rather than with the game.
    static let graphicsDLLs: Set<String> = [
        "d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d10core.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll",
        "winemetal.dll", "vulkan-1.dll", "opengl32.dll", "ddraw.dll",
    ]

    static let antiCheats = ["EasyAntiCheat", "BattlEye", "BEService", "vgk.sys", "EAAntiCheat", "nProtect", "XIGNCODE"]

    public init(log: String) {
        let lines = log.split(whereSeparator: \.isNewline).map(String.init)
        func last(_ needles: String...) -> String? {
            lines.last { line in needles.contains { line.localizedCaseInsensitiveContains($0) } }
        }

        var found: (Problem, String)?
        if let line = last("Support for DirectX 12 is required", "D3D12CreateDevice failed") {
            found = (.directX12, line)
        } else if let name = Self.antiCheats.first(where: { last($0) != nil }), let line = last(name) {
            found = (.antiCheat(name), line)
        } else if let (dll, line) = Self.missingDLL(in: lines) {
            // A DLL a Windows system file needs (winemetal.dll for DXMT's DXGI) is the backend's, not the game's.
            found = Self.graphicsDLLs.contains(dll.lowercased()) || line.lowercased().contains(#"c:\\windows\\"#)
                ? (.graphics, line) : (.missingFile(dll), line)
        } else if let line = last(
            "Failed to create metal view",  // DXMT on a Wine that doesn't export what it needs
            "D3D11CoreCreateDevice: Failed", "Failed to create D3D11 device",
            "None of the requested D3D feature levels is supported",  // WineD3D's OpenGL stops below the game's level
            "Only external memory handle type VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER",  // 32-bit D3D11 on DXVK
            "VK_ERROR_DEVICE_LOST", "VK_ERROR_INITIALIZATION_FAILED", "Failed to initialize graphics") {
            found = (.graphics, line)
        } else if let line = last("Unhandled page fault", "page fault on")
            ?? lines.last(where: { $0.contains("Unhandled exception") && !$0.contains("0x80000003") }) {
            found = (.crash, line)
        }
        problem = found?.0
        evidence = found.map { Self.trim($0.1) }

        var seen = Set<String>()
        excerpt = lines.filter { line in
            let interesting = line.hasPrefix("[EscApp]") || line.contains("err:") || line.contains("Unhandled")
                || line.contains("mvk-error") || line.localizedCaseInsensitiveContains("fail")
            return interesting && !line.hasPrefix("\t") && seen.insert(Self.trim(line)).inserted
        }.suffix(40).map(Self.trim)
    }

    /// `err:module:import_dll Library binkw32.dll (which is needed by L"Z:\\…\\game.exe") not found`
    static func missingDLL(in lines: [String]) -> (String, String)? {
        guard let line = lines.last(where: { $0.contains("err:module:import_dll") && $0.contains("not found") }),
              let range = line.range(of: #"Library [^\s]+"#, options: .regularExpression) else { return nil }
        return (String(line[range].dropFirst("Library ".count)), line)
    }

    /// Only the start and the end of a log: DXVK and MoltenVK can write megabytes of feature lists in between.
    public static func read(_ url: URL, headBytes: Int = 64 << 10, tailBytes: Int = 1 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard size > UInt64(headBytes + tailBytes) else {
            return (try? handle.readToEnd()).map(text)
        }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        try? handle.seek(toOffset: size - UInt64(tailBytes))
        let tail = (try? handle.readToEnd()) ?? Data()
        return text(head) + "\n" + text(tail)
    }

    /// Wine writes UTF-8, but a tail cut mid-character isn't valid UTF-8; Latin-1 reads any bytes, and the lines
    /// that matter are ASCII.
    private static func text(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    static func trim(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
    }
}
