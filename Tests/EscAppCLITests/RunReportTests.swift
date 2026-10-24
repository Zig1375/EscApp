@testable import EscAppCLI
@testable import EscAppKit
import Foundation
import Testing

@Suite struct RunReportTests {
    let attempt = LaunchAttempt(backend: .dxvk, seconds: 90, failure: nil, diagnosis: LogDiagnosis(log: ""),
                                log: URL(filePath: "/tmp/run.log"))

    @Test func checkedAttemptWorked() {
        #expect(EscAppCommand.describe(attempt) == "DXVK: worked")
    }

    @Test func uncheckedAttemptOnlyRan() {
        // A Steam game's single attempt: EscApp never saw its window, so it can't say it worked.
        #expect(EscAppCommand.describe(attempt, judged: false) == "DXVK: ran, not checked")
    }
}
