import Foundation
@testable import MagicKettleCLI
@testable import MagicKettleKit
import Testing

@Suite struct RunReportTests {
    let attempt = LaunchAttempt(backend: .dxvk, seconds: 90, failure: nil, diagnosis: LogDiagnosis(log: ""),
                                log: URL(filePath: "/tmp/run.log"))

    @Test func checkedAttemptWorked() {
        #expect(MagicKettleCommand.describe(attempt) == "DXVK: worked")
    }

    @Test func uncheckedAttemptOnlyRan() {
        // A Steam game's single attempt: Magic Kettle never saw its window, so it can't say it worked.
        #expect(MagicKettleCommand.describe(attempt, judged: false) == "DXVK: ran, not checked")
    }
}
