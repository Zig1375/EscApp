import Foundation

/// Enigma Virtual Box packs a program's files into its exe and serves them to it from memory. A whole NW.js game
/// fits ("Wife Tsuma Uninhabited Island", `Game_boxed.exe`, 735 MB): nothing beside the exe, nor in its imports
/// (the box's loader takes Chromium's DLLs from inside), says Chromium. The box's table of file names does.
enum EnigmaVirtualBox {
    /// The section with the packed files. Their table of names comes first.
    static let section = ".enigma1"
    /// How much of the section's start is read for names. "Wife Tsuma"'s table held 680 names in 64 KB, Chromium's
    /// own files in the first 12 KB.
    static let tableBytes = 256 * 1024

    /// The lowercased names in `table`, the start of the section: UTF-16 runs of printable ASCII, at any offset.
    /// Folder entries and other text come along; they only ever add names that are looked up and not found.
    static func fileNames(in table: Data) -> Set<String> {
        let bytes = [UInt8](table)
        var names = Set<String>()
        for start in 0..<2 {
            var run: [UInt8] = []
            var index = start
            while index + 1 < bytes.count {
                if bytes[index + 1] == 0, (0x20...0x7E).contains(bytes[index]) {
                    run.append(bytes[index])
                } else {
                    if run.count >= 3 { names.insert(String(bytes: run, encoding: .ascii)?.lowercased() ?? "") }
                    run.removeAll(keepingCapacity: true)
                }
                index += 2
            }
            if run.count >= 3 { names.insert(String(bytes: run, encoding: .ascii)?.lowercased() ?? "") }
        }
        names.remove("")
        return names
    }
}
