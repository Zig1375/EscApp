@testable import ExePortKit
import Foundation
import Testing

@Suite struct WineRegistryTests {
    /// Trimmed from a real `user.reg` written by Wine 11.18.
    let userReg = #"""
    WINE REGISTRY Version 2
    ;; All keys relative to \\User\\S-1-5-21-0-0-0-1000

    #arch=win64

    [Control Panel\\Desktop] 1792780000
    #time=1dc4f2a8e0b1c00
    "FontSmoothing"="2"
    "WheelScrollLines"="3"

    [Software\\Wine\\Drivers] 1792780000
    #time=1dc4f2a8e0b1c00
    "Graphics"="mac"

    """#

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func addsAMissingKeyAtTheEnd() {
        let edited = WindowsVersion.windows7.write(toUserReg: userReg)
        #expect(WindowsVersion.read(fromUserReg: edited) == .windows7)
        #expect(edited.contains("[Software\\\\Wine] "))
        // The neighbouring key with a longer name is untouched.
        #expect(WineRegistry.string(in: edited, key: #"Software\Wine\Drivers"#, name: "Graphics") == "mac")
        #expect(edited.hasPrefix("WINE REGISTRY Version 2\n"))
    }

    @Test func replacesAnExistingValue() {
        let once = WindowsVersion.windows7.write(toUserReg: userReg)
        let twice = WindowsVersion.windowsXP.write(toUserReg: once)
        #expect(WindowsVersion.read(fromUserReg: twice) == .windowsXP)
        #expect(twice.components(separatedBy: "\"Version\"=").count == 2)
    }

    @Test func insertsIntoAnExistingKeyAfterItsHeader() {
        let edited = WineRegistry.setString(in: userReg, key: #"Control Panel\Desktop"#, name: "DragWidth",
                                            value: "4", now: now)
        let lines = edited.components(separatedBy: "\n")
        let header = lines.firstIndex { $0.hasPrefix("[Control Panel\\\\Desktop]") }!
        #expect(lines[header + 1].hasPrefix("#time="))
        #expect(lines[header + 2] == #""DragWidth"="4""#)
        #expect(WineRegistry.string(in: edited, key: #"control panel\desktop"#, name: "fontsmoothing") == "2")
    }

    @Test func escapesQuotesAndBackslashes() {
        let value = #"C:\Games\"Quoted""#
        let edited = WineRegistry.setString(in: userReg, key: #"Software\App"#, name: "Path", value: value, now: now)
        #expect(WineRegistry.string(in: edited, key: #"Software\App"#, name: "Path") == value)
    }

    @Test func writesDWordsAndReplacesAnyTypeOfValue() {
        let key = #"Software\Wine\WineDbg"#
        var text = WineRegistry.setDWord(in: userReg, key: key, name: "ShowCrashDialog", value: 1, now: now)
        #expect(WineRegistry.contains(text, key: key, entry: #""ShowCrashDialog"=dword:00000001"#))
        text = WineRegistry.setDWord(in: text, key: key, name: "ShowCrashDialog", value: 0, now: now)
        #expect(WineRegistry.contains(text, key: key, entry: #""ShowCrashDialog"=dword:00000000"#))
        #expect(text.components(separatedBy: "ShowCrashDialog").count == 2)
    }

    @Test func missingKeyOrValueReadsAsNil() {
        #expect(WindowsVersion.read(fromUserReg: userReg) == nil)
        #expect(WineRegistry.string(in: userReg, key: #"Control Panel\Desktop"#, name: "Nope") == nil)
    }
}
