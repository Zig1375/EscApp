import Foundation
@testable import MagicKettleKit
import Testing

@Suite struct RawDiscTests {
    /// A CD's raw copy of `data`: each 2048 bytes in a MODE1 sector of 2352, then `audio` sectors of music.
    static func rawImage(_ data: Data, audioSectors: Int = 0) -> Data {
        var raw = Data()
        let sectors = data.count / 2048
        for sector in 0..<sectors {
            raw.append(RawDisc.sync)
            raw.append(contentsOf: [0, 2, UInt8(sector % 75), 1])  // address, mode 1
            raw.append(data[(sector * 2048)..<((sector + 1) * 2048)])
            raw.append(Data(repeating: 0xEC, count: 288))  // error correction
        }
        raw.append(Data(repeating: 0x55, count: audioSectors * 2352))
        return raw
    }

    static let iso = Data((0..<(2048 * 40)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 2048) })

    @Test func aBinCueBecomesTheISOOfItsDataTrack() throws {
        let temp = try TempFolder()
        let paths = AppPaths(root: temp.url.appending(path: "Home"), games: temp.url)
        try Self.rawImage(Self.iso, audioSectors: 30).write(to: temp.url.appending(path: "My Game.bin"))
        let cue = temp.url.appending(path: "My Game.cue")
        try Data("""
            FILE "My Game.bin" BINARY
              TRACK 01 MODE1/2352
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 00 00:00:38
                INDEX 01 00:00:40
            """.utf8).write(to: cue)

        #expect(RawDisc.isRaw(cue))
        let iso = try RawDisc.iso(for: cue, paths: paths)
        #expect(try Data(contentsOf: iso) == Self.iso)
        // Made once: the second time it is the same file.
        let modified = try iso.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(try RawDisc.iso(for: cue, paths: paths) == iso)
        #expect(try iso.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    }

    @Test func aRawImageWithoutCueIsReadFromItsSyncPattern() throws {
        let temp = try TempFolder()
        let paths = AppPaths(root: temp.url.appending(path: "Home"), games: temp.url)
        let image = temp.url.appending(path: "game.img")
        try Self.rawImage(Self.iso).write(to: image)
        #expect(RawDisc.isRaw(image))
        #expect(try Data(contentsOf: RawDisc.iso(for: image, paths: paths)) == Self.iso)

        let plain = temp.url.appending(path: "plain.img")
        try Self.iso.write(to: plain)
        #expect(!RawDisc.isRaw(plain))
    }

    @Test func cueSheetsPickTheDataTrack() {
        let mixed = """
            FILE "a.bin" BINARY
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 MODE2/2352
                INDEX 01 00:04:00
              TRACK 03 AUDIO
                INDEX 01 01:00:00
            """
        #expect(RawDisc.dataTrack(cue: mixed)
            == RawDisc.Track(file: "a.bin", sectorSize: 2352, dataOffset: 24, start: 300, end: 4500))
        #expect(RawDisc.dataTrack(cue: "FILE \"m.bin\" BINARY\n TRACK 01 AUDIO\n INDEX 01 00:00:00") == nil)
        let cooked = "FILE game.iso BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:00"
        #expect(RawDisc.dataTrack(cue: cooked)?.sectorSize == 2048)
    }

    @Test func discImagesIncludeRawOnes() {
        for name in ["g.iso", "g.cue", "g.bin", "g.mdf", "g.IMG"] {
            #expect(DiscImage.isImage(URL(filePath: "/x/\(name)")), "\(name)")
        }
    }
}

@Suite struct DiscRequestTests {
    @Test func aMessageBoxAskingForTheCDIsRecognised() {
        let log = """
            [Magic Kettle] Launch 2026-10-24
            0024:trace:msgbox:MSGBOX_OnInit L"Please insert the Fallout 2 CD into your CD-ROM drive."
            """
        let diagnosis = LogDiagnosis(log: log)
        #expect(diagnosis.problem == .needsDisc)
        #expect(!diagnosis.retryHelps)
        #expect(diagnosis.excerpt.contains { $0.contains("Please insert") })
    }

    @Test func otherLanguagesAndOtherMessages() {
        #expect(LogDiagnosis.asksForDisc(#"0024:trace:msgbox:MSGBOX_OnInit L"Bitte legen Sie die CD ein""#))
        #expect(LogDiagnosis.asksForDisc(#"0024:trace:msgbox:MSGBOX_OnInit L"Bitte die CD einlegen""#))
        #expect(LogDiagnosis.asksForDisc(#"0024:trace:msgbox:x L"Veuillez ins\xe9rer le disque 2""#))
        #expect(LogDiagnosis.asksForDisc(#"0024:trace:msgbox:x L"Inserisci il disco""#))
        #expect(LogDiagnosis.asksForDisc(#"0024:trace:msgbox:x L"Insert Disc 2 and press OK""#))
        #expect(!LogDiagnosis.asksForDisc(#"0024:trace:msgbox:x L"Your CD key is invalid""#))
        #expect(!LogDiagnosis.asksForDisc("err:module: insert the CD"))
    }

    @Test func theMessageIsReadAsTheGameWroteIt() {
        let line = #"0024:trace:msgbox:MSGBOX_OnInit L"Please insert\nthe \"Gold\" CD""#
        #expect(LogDiagnosis.messageText(line) == #"Please insert the "Gold" CD"#)
    }
}
