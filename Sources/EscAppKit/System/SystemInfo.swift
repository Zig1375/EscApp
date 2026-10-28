import Foundation
import IOKit

/// The Mac and the EscApp a log was written on. A player sends a log without saying which Mac, macOS or EscApp
/// build they have, and a crash that only one chip or one macOS shows, or one an update already fixed, can't be
/// told apart without it. Only read, never sent anywhere.
public struct SystemInfo: Sendable, Equatable {
    /// "0.1.0 (1)"; "command line" for `escapp`, which has no bundle.
    public var app: String
    /// "27.0.1 (26A434)"
    public var macOS: String
    /// "MacBook Pro (16-inch, 2023)"; empty when the Mac doesn't say.
    public var modelName: String
    /// "Mac14,6"
    public var modelID: String
    /// "Apple M2 Max"
    public var chip: String
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var memoryBytes: UInt64
    /// The Mac's first preferred language, like "ru-RU".
    public var language: String
    public var rosetta: Bool

    public static let current = read()

    /// "MacBook Pro (16-inch, 2023) (Mac14,6)"
    public var model: String { modelName.isEmpty ? modelID : "\(modelName) (\(modelID))" }

    /// "Apple M2 Max, 8P + 4E cores, 32 GB memory"
    public var hardware: String {
        let cores = efficiencyCores > 0 ? "\(performanceCores)P + \(efficiencyCores)E cores"
            : "\(performanceCores) cores"
        let memory = Int((Double(memoryBytes) / Double(1 << 30)).rounded())
        return "\(chip), \(cores), \(memory) GB memory"
    }

    /// One line for "Copy Report".
    public var summary: String { "\(model), \(hardware)" }

    /// `[EscApp] …` lines for the top of a log.
    public var logLines: [String] {
        [
            "[EscApp] EscApp \(app)",
            "[EscApp] macOS \(macOS)",
            "[EscApp] Mac \(model)",
            "[EscApp] Chip \(hardware)",
            "[EscApp] Mac language \(language), Rosetta \(rosetta ? "installed" : "missing")",
        ]
    }

    static func read() -> SystemInfo {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let app = short.map { version in build.map { "\(version) (\($0))" } ?? version } ?? "command line"
        let version = sysctlString("kern.osproductversion")
            ?? ProcessInfo.processInfo.operatingSystemVersionString
        let osBuild = sysctlString("kern.osversion").map { " (\($0))" } ?? ""
        let performance = sysctlInt("hw.perflevel0.physicalcpu") ?? ProcessInfo.processInfo.processorCount
        return SystemInfo(app: app, macOS: version + osBuild, modelName: productName() ?? "",
                          modelID: sysctlString("hw.model") ?? "?",
                          chip: sysctlString("machdep.cpu.brand_string") ?? "?",
                          performanceCores: performance, efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu") ?? 0,
                          memoryBytes: ProcessInfo.processInfo.physicalMemory,
                          language: Locale.preferredLanguages.first ?? "?", rosetta: Rosetta.isInstalled())
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let text = String(bytes: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
        return text?.isEmpty == false ? text : nil
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// The marketing name Apple Silicon Macs keep in the device tree ("MacBook Pro (16-inch, 2023)"), which
    /// `hw.model` ("Mac14,6") doesn't tell a person.
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(bytes: data.prefix { $0 != 0 }, encoding: .utf8)
        return name?.isEmpty == false ? name : nil
    }
}

/// The first lines of every log EscApp writes: the Mac and app (`SystemInfo`), then the runtime the Wine
/// belongs to and each of its components by version and checksum, so a log names exactly what ran even when
/// a rebuilt component kept its version.
public enum LogHeader {
    public static func lines(system: SystemInfo = .current, wine: Wine) -> [String] {
        lines(system: system, runtime: wine.runtime)
    }

    static func lines(system: SystemInfo, runtime: RuntimeManifest.Runtime?) -> [String] {
        var lines = system.logLines
        guard let runtime else { return lines + ["[EscApp] Runtime unknown"] }
        lines.append("[EscApp] Runtime \(runtime.id)")
        for component in runtime.components {
            lines.append("[EscApp] Component \(component.kind.rawValue) \(component.version) "
                + String(component.sha256.prefix(12)))
        }
        return lines
    }

    /// Which D3DMetal the player added and from which of Apple's images, so a Direct3D 12 game's log says what
    /// it ran on, and a game that failed on other backends shows whether D3DMetal was there to try.
    static func d3dmetalLine(_ installed: D3DMetal.Installed?) -> String {
        guard let installed else { return "[EscApp] D3DMetal not added" }
        return "[EscApp] D3DMetal \(installed.version) from \(installed.source)"
    }

    /// The header as text ready to write, ending in a newline.
    public static func text(system: SystemInfo = .current, wine: Wine) -> String {
        lines(system: system, wine: wine).joined(separator: "\n") + "\n"
    }
}
