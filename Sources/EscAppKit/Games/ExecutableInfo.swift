import Foundation

/// What an executable tells about itself without running it: format and bitness, imported DLLs (which give
/// away the DirectX version), its name, icon and whether it handles high-DPI screens.
public struct ExecutableInfo: Sendable, Equatable {
    public enum Format: String, Sendable, Equatable, Codable {
        case pe32, pe64
        /// 16-bit Windows (NE). Wine on macOS can't run these.
        case win16
        /// A DOS program (plain MZ, or LE/LX with a DOS extender). Needs DOSBox, not Wine.
        case dos
    }

    public var format: Format
    /// Lowercased DLL names, including delay-loaded ones.
    public var imports: Set<String>
    /// ProductName, or FileDescription, from the version resource.
    public var productName: String?
    /// The main icon as `.ico` file data, ready for `NSImage(data:)`.
    public var icon: Data?
    /// The manifest declares high-DPI support, so the game draws its UI for Retina itself.
    public var dpiAware: Bool
    /// Every string of the version resource (`CompanyName`, `FileDescription`, `Comments`…).
    public var versionStrings: [String: String] = [:]
    /// The embedded application manifest.
    public var manifest: String?
    /// A Chromium program (`ChromiumApp`), known from the files beside it when read from disk.
    public var chromium = false

    public var directX: Set<ExecutableTraits.DirectX> {
        var result = Set<ExecutableTraits.DirectX>()
        for name in imports {
            if ["ddraw.dll", "d3d8.dll", "d3dim.dll", "d3drm.dll"].contains(name) { result.insert(.legacy) }
            if name == "d3d9.dll" || name.hasPrefix("d3dx9") { result.insert(.d3d9) }
            // A Unity game's exe imports only UnityPlayer.dll, which loads d3d11.dll at run time (Unity's default
            // on Windows): 凛姦小屋 got the short no-imports plan and never tried DXMT.
            if name.hasPrefix("d3d10") || name == "d3d11.dll" || name.hasPrefix("dxgi")
                || name.hasPrefix("d3dx11") || name == "unityplayer.dll" {
                result.insert(.d3d11)
            }
            // Chromium links d3d12.dll for WebGPU and draws through Direct3D 11 (Electron 33 does).
            if name == "d3d12.dll", !chromium { result.insert(.d3d12) }
        }
        return result
    }

    public var traits: ExecutableTraits {
        let architecture: ExecutableTraits.Architecture = switch format {
        case .pe64: .x64
        case .pe32: .x86
        case .win16, .dos: .win16
        }
        return ExecutableTraits(architecture: architecture, directX: directX, isChromium: chromium)
    }

    public static func read(_ url: URL) throws -> ExecutableInfo {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var info = try PEReader(data: data).read()
        info.chromium = ChromiumApp.isChromium(executable: url, imports: info.imports)
        return info
    }
}

public enum ExecutableError: Error, Equatable, CustomStringConvertible {
    case notAnExecutable
    case damaged(String)

    public var description: String {
        switch self {
        case .notAnExecutable: "This file isn't a Windows program."
        case let .damaged(part): "This program looks damaged (\(part))."
        }
    }
}

/// A bounds-checked reader of the PE format: headers, sections, imports, resources.
struct PEReader {
    let data: Data

    private enum Directory: Int {
        case imports = 1, resources = 2, delayImports = 13
    }

    private enum ResourceType: UInt32 {
        case icon = 3, groupIcon = 14, version = 16, manifest = 24
    }

    private struct Section {
        var virtualAddress: Int
        var virtualSize: Int
        var rawOffset: Int
        var rawSize: Int
    }

    /// Where the PE headers say things are, once the file is known to be PE.
    private struct Layout {
        var is64: Bool
        var imageBase: Int
        var directories: Int
        var directoryCount: Int
        var sections: [Section]
    }

    func read() throws -> ExecutableInfo {
        guard data.count >= 64, u16(0) == 0x5A4D else { throw ExecutableError.notAnExecutable }  // "MZ"
        let header = Int(u32(0x3C) ?? 0)
        guard u32(header) == 0x0000_4550 else {  // "PE\0\0"
            // "NE" is 16-bit Windows; anything else is DOS (plain, or LE/LX with a DOS extender).
            let format: ExecutableInfo.Format = u16(header) == 0x454E ? .win16 : .dos
            return ExecutableInfo(format: format, imports: [], productName: nil, icon: nil, dpiAware: false)
        }
        let layout = try readLayout(peHeader: header)
        var info = ExecutableInfo(format: layout.is64 ? .pe64 : .pe32, imports: readImports(layout),
                                  productName: nil, icon: nil, dpiAware: false)
        if let root = directory(.resources, layout) {
            let resources = Resources(reader: self, root: root) { Self.offset(of: $0, in: layout.sections) }
            info.versionStrings = resources.first(.version).map(versionStrings) ?? [:]
            info.productName = Self.versionName(info.versionStrings)
            info.icon = iconFile(resources)
            if let manifest = resources.first(.manifest), let text = String(data: manifest, encoding: .utf8) {
                info.manifest = text
                info.dpiAware = Self.declaresDPIAwareness(text)
            }
        }
        return info
    }

    private func readLayout(peHeader header: Int) throws -> Layout {
        let coff = header + 4
        guard let sectionCount = u16(coff + 2), let optionalSize = u16(coff + 16) else {
            throw ExecutableError.damaged("header")
        }
        let optional = coff + 20
        let magic = u16(optional)
        let is64 = magic == 0x20B
        guard is64 || magic == 0x10B else { throw ExecutableError.damaged("optional header") }
        let directories = optional + (is64 ? 112 : 96)

        var sections: [Section] = []
        let sectionTable = optional + Int(optionalSize)
        for index in 0..<Int(sectionCount) {
            let entry = sectionTable + index * 40
            guard let size = u32(entry + 8), let address = u32(entry + 12), let rawSize = u32(entry + 16),
                  let rawOffset = u32(entry + 20) else { throw ExecutableError.damaged("sections") }
            sections.append(Section(virtualAddress: Int(address), virtualSize: Int(size), rawOffset: Int(rawOffset),
                                    rawSize: Int(rawSize)))
        }
        return Layout(is64: is64,
                      imageBase: is64 ? Int(u64(optional + 24) ?? 0) : Int(u32(optional + 28) ?? 0),
                      directories: directories, directoryCount: Int(u32(directories - 4) ?? 0), sections: sections)
    }

    private func directory(_ entry: Directory, _ layout: Layout) -> Int? {
        guard entry.rawValue < layout.directoryCount, let rva = u32(layout.directories + entry.rawValue * 8),
              rva != 0 else { return nil }
        return Self.offset(of: Int(rva), in: layout.sections)
    }

    private func readImports(_ layout: Layout) -> Set<String> {
        let map = { (rva: Int) -> Int? in Self.offset(of: rva, in: layout.sections) }
        var imports = Set<String>()
        if var entry = directory(.imports, layout) {
            while let nameRVA = u32(entry + 12), nameRVA != 0, imports.count < 512 {
                if let offset = map(Int(nameRVA)), let name = cString(offset) { imports.insert(name.lowercased()) }
                entry += 20
            }
        }
        if var entry = directory(.delayImports, layout) {
            while let attributes = u32(entry), let nameValue = u32(entry + 4), nameValue != 0, imports.count < 512 {
                // Old linkers wrote a virtual address instead of an RVA (attribute bit 0 clear).
                let rva = attributes & 1 == 1 ? Int(nameValue) : Int(nameValue) - layout.imageBase
                if let offset = map(rva), let name = cString(offset) { imports.insert(name.lowercased()) }
                entry += 32
            }
        }
        return imports
    }

    static func declaresDPIAwareness(_ manifest: String) -> Bool {
        let lower = manifest.lowercased()
        for tag in ["dpiaware", "dpiawareness"] {
            guard let open = lower.range(of: "<\(tag)"),
                  let close = lower.range(of: "</\(tag)>", range: open.upperBound..<lower.endIndex)
            else { continue }
            let value = lower[open.upperBound..<close.lowerBound]
            if value.contains("true") || value.contains("permonitor") || value.contains("system") { return true }
        }
        return false
    }

    // MARK: Resources

    /// Resources by type, each a list of (id, data) in file order.
    private struct Resources {
        var byType: [UInt32: [(id: UInt32, data: Data)]] = [:]

        init(reader: PEReader, root: Int, map: (Int) -> Int?) {
            for (type, typeDirectory) in reader.entries(at: root, root: root)
            where ResourceType(rawValue: type) != nil {
                guard let typeDirectory else { continue }
                for (id, nameDirectory) in reader.entries(at: typeDirectory, root: root) {
                    guard let nameDirectory else { continue }
                    // First language is enough: games rarely ship icons per language.
                    for (_, leaf) in reader.entries(at: nameDirectory, root: root).prefix(1) {
                        guard let leaf, let rva = reader.u32(leaf), let size = reader.u32(leaf + 4),
                              let offset = map(Int(rva)), let data = reader.slice(offset, Int(size))
                        else { continue }
                        byType[type, default: []].append((id, data))
                    }
                }
            }
        }

        func first(_ type: ResourceType) -> Data? { byType[type.rawValue]?.first?.data }
        func all(_ type: ResourceType) -> [(id: UInt32, data: Data)] { byType[type.rawValue] ?? [] }
    }

    /// Entries of a resource directory: (id, offset of the child). Subdirectories and leaves both come back as
    /// offsets; named entries get id 0. A nil child means the entry pointed outside the file.
    private func entries(at directory: Int, root: Int) -> [(UInt32, Int?)] {
        guard let named = u16(directory + 12), let numbered = u16(directory + 14) else { return [] }
        let count = min(Int(named) + Int(numbered), 4096)
        return (0..<count).compactMap { index in
            let entry = directory + 16 + index * 8
            guard let name = u32(entry), let target = u32(entry + 4) else { return nil }
            let id = name & 0x8000_0000 == 0 ? name : 0
            let child = root + Int(target & 0x7FFF_FFFF)
            return (id, child < data.count ? child : nil)
        }
    }

    /// Rebuilds a standalone `.ico` from the first icon group: the group lists sizes, the images are separate
    /// RT_ICON resources found by id.
    private func iconFile(_ resources: Resources) -> Data? {
        guard let group = resources.first(.groupIcon), group.count >= 6 else { return nil }
        let images = Dictionary(resources.all(.icon).map { ($0.id, $0.data) }) { first, _ in first }
        let count = Int(group.u16le(4) ?? 0)
        var entries: [(header: Data, image: Data)] = []
        for index in 0..<count {
            let base = 6 + index * 14
            guard base + 14 <= group.count, let id = group.u16le(base + 12), let image = images[UInt32(id)] else {
                continue
            }
            entries.append((group.subdata(in: group.startIndex + base..<group.startIndex + base + 12), image))
        }
        guard !entries.isEmpty else { return nil }
        var ico = Data([0, 0, 1, 0])
        ico.appendLE(UInt16(entries.count))
        var offset = 6 + entries.count * 16
        for entry in entries {
            ico.append(entry.header.prefix(8))  // width, height, colours, reserved, planes, bit count
            ico.appendLE(UInt32(entry.image.count))
            ico.appendLE(UInt32(offset))
            offset += entry.image.count
        }
        for entry in entries { ico.append(entry.image) }
        return ico
    }

    /// ProductName (or FileDescription) from a VS_VERSIONINFO block.
    private func versionStrings(_ block: Data) -> [String: String] {
        var strings: [String: String] = [:]
        Self.walkVersionBlock(block, offset: 0, path: [], into: &strings)
        return strings
    }

    private static func versionName(_ strings: [String: String]) -> String? {
        for key in ["ProductName", "FileDescription"] {
            if let value = strings[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Each block: length, value length, type, UTF-16 key, padding, value, padding, children.
    private static func walkVersionBlock(_ data: Data, offset: Int, path: [String],
                                         into strings: inout [String: String], depth: Int = 0) {
        guard depth < 6, let length = data.u16le(offset), length >= 6, offset + Int(length) <= data.count,
              let valueLength = data.u16le(offset + 2), let type = data.u16le(offset + 4) else { return }
        let end = offset + Int(length)
        var cursor = offset + 6
        var key = ""
        while cursor + 1 < end, let unit = data.u16le(cursor), unit != 0 {
            key.unicodeScalars.append(Unicode.Scalar(unit) ?? "?")
            cursor += 2
        }
        cursor = (cursor + 2 + 3) & ~3
        if path.count == 2, path[0] == "StringFileInfo" {
            // Value length counts characters for text (type 1), but some compilers (Wine's among them) mark
            // strings as binary and count bytes.
            let byteCount = min(type == 1 ? Int(valueLength) * 2 : Int(valueLength), end - cursor)
            if byteCount > 0, strings[key] == nil {
                let raw = data.subdata(in: data.startIndex + cursor..<data.startIndex + cursor + byteCount)
                strings[key] = String(data: raw, encoding: .utf16LittleEndian)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
            return
        }
        cursor += type == 1 ? Int(valueLength) * 2 : Int(valueLength)
        cursor = (cursor + 3) & ~3
        let childPath = depth == 0 ? [] : path + [key]
        while cursor + 6 <= end, let childLength = data.u16le(cursor), childLength > 0 {
            walkVersionBlock(data, offset: cursor, path: childPath, into: &strings, depth: depth + 1)
            cursor = (cursor + Int(childLength) + 3) & ~3
        }
    }

    // MARK: Primitives

    private static func offset(of rva: Int, in sections: [Section]) -> Int? {
        for section in sections {
            let size = max(section.virtualSize, section.rawSize)
            if rva >= section.virtualAddress, rva < section.virtualAddress + size {
                let offset = section.rawOffset + rva - section.virtualAddress
                return offset < section.rawOffset + section.rawSize ? offset : nil
            }
        }
        return nil
    }

    func u16(_ offset: Int) -> UInt16? { data.u16le(offset) }
    func u32(_ offset: Int) -> UInt32? { data.u32le(offset) }
    func u64(_ offset: Int) -> UInt64? {
        guard let low = u32(offset), let high = u32(offset + 4) else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }

    func slice(_ offset: Int, _ count: Int) -> Data? {
        guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
        return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count)
    }

    func cString(_ offset: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        let start = data.startIndex + offset
        let end = data[start...].prefix(256).firstIndex(of: 0) ?? min(start + 256, data.endIndex)
        return String(data: data[start..<end], encoding: .ascii)
    }
}

extension Data {
    func u16le(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func u32le(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }

    mutating func appendLE(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func appendLE(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }
}
