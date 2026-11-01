import Foundation
@testable import MagicKettleKit
import Testing

@Suite struct LogRotationTests {
    @Test func keepsTheNewestThreeOfEachKind() {
        let runs = (1...5).map { "2026-10-2\($0)_10-00-00.log" }
        let installs = ["install-2026-10-01_09-00-00.log", "install-2026-10-02_09-00-00.log"]
        let updates = (1...4).map { "steam-update-2026-10-0\($0)_08-00-00.log" }
        let stale = Set(LogRotation.stale(runs + installs + updates, keep: 3))
        // Installs sort after the dates; on their own they no longer push out the runs.
        #expect(stale == ["2026-10-21_10-00-00.log", "2026-10-22_10-00-00.log",
                          "steam-update-2026-10-01_08-00-00.log"])
    }

    @Test func pruneRemovesOnlyOldLogs() throws {
        let temp = try TempFolder()
        for name in ["2026-01-01_00-00-00.log", "2026-01-02_00-00-00.log", "2026-01-03_00-00-00.log",
                     "2026-01-04_00-00-00.log", "notes.txt"] {
            try Data().write(to: temp.url.appending(path: name))
        }
        LogRotation.prune(temp.url)
        let left = try FileManager.default.contentsOfDirectory(atPath: temp.url.path).sorted()
        #expect(left == ["2026-01-02_00-00-00.log", "2026-01-03_00-00-00.log", "2026-01-04_00-00-00.log",
                         "notes.txt"])
    }
}
