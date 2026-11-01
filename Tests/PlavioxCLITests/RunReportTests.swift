import Foundation
@testable import PlavioxCLI
@testable import PlavioxKit
import Testing

@Suite struct RunReportTests {
    let attempt = LaunchAttempt(backend: .dxvk, seconds: 90, failure: nil, diagnosis: LogDiagnosis(log: ""),
                                log: URL(filePath: "/tmp/run.log"))

    @Test func checkedAttemptWorked() {
        #expect(PlavioxCommand.describe(attempt) == "DXVK: worked")
    }

    @Test func uncheckedAttemptOnlyRan() {
        // A Steam game's single attempt: Plaviox never saw its window, so it can't say it worked.
        #expect(PlavioxCommand.describe(attempt, judged: false) == "DXVK: ran, not checked")
    }
}
