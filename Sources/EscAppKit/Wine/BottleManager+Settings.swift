import Foundation

extension BottleManager {
    /// `EmulateModeset` lets a game switch to a low resolution without touching the Mac's display.
    /// `StretchWindows` (EscApp's Wine) lets the player drag the corner of a game window that can't be resized:
    /// a Unity game with a fixed 1440×800 window was half the screen on a Retina Mac and couldn't be made bigger.
    /// The window keeps its size for the game and Wine scales the picture and the mouse. Both keys are the X11
    /// driver's by name, but Wine's core reads them for every driver.
    static func enableScaling(bottle: URL) throws {
        let key = #"Software\Wine\X11 Driver"#
        try setRegistryString(bottle: bottle, key: key, name: "EmulateModeset", value: "y")
        try setRegistryString(bottle: bottle, key: key, name: "StretchWindows", value: "y")
    }

    static func disableCrashDialog(bottle: URL) throws {
        let userReg = bottle.appending(path: "user.reg")
        let text = try String(contentsOf: userReg, encoding: .utf8)
        let key = #"Software\Wine\WineDbg"#
        guard !WineRegistry.contains(text, key: key, entry: #""ShowCrashDialog"=dword:00000000"#) else { return }
        try WineRegistry.setDWord(in: text, key: key, name: "ShowCrashDialog", value: 0)
            .write(to: userReg, atomically: true, encoding: .utf8)
    }

    /// Sets a DWORD in the bottle's `user.reg`, writing only if it changes. Only while the bottle is idle.
    static func setRegistryDWord(bottle: URL, key: String, name: String, value: UInt32) throws {
        let userReg = bottle.appending(path: "user.reg")
        let text = try String(contentsOf: userReg, encoding: .utf8)
        let hex = String(value, radix: 16)
        let entry = "\"\(name)\"=dword:\(String(repeating: "0", count: 8 - hex.count))\(hex)"
        guard !WineRegistry.contains(text, key: key, entry: entry) else { return }
        try WineRegistry.setDWord(in: text, key: key, name: name, value: value)
            .write(to: userReg, atomically: true, encoding: .utf8)
    }

    /// Sets a string in the bottle's `user.reg` (or `system.reg`, for keys under HKLM), writing only if it
    /// changes. Only while the bottle is idle.
    static func setRegistryString(bottle: URL, key: String, name: String, value: String,
                                  file: String = "user.reg") throws {
        let userReg = bottle.appending(path: file)
        let text = try String(contentsOf: userReg, encoding: .utf8)
        guard WineRegistry.string(in: text, key: key, name: name) != value else { return }
        try WineRegistry.setString(in: text, key: key, name: name, value: value)
            .write(to: userReg, atomically: true, encoding: .utf8)
    }
}
