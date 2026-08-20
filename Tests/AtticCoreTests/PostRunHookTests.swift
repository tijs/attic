@testable import AtticCore
import Foundation
import Testing

struct PostRunHookTests {
    @Test func runsCommandWithEnvironment() throws {
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outFile) }

        let status = PostRunHook.run(
            command: "printf '%s %s' \"$ATTIC_RESULT\" \"$ATTIC_UPLOADED\" > \(outFile.path)",
            environment: ["ATTIC_RESULT": "success", "ATTIC_UPLOADED": "42"],
        )

        #expect(status == 0)
        #expect(try String(contentsOf: outFile, encoding: .utf8) == "success 42")
    }

    @Test func returnsHookExitStatus() {
        #expect(PostRunHook.run(command: "exit 3", environment: [:]) == 3)
    }

    @Test func returnsNilWhenShellCannotLaunch() {
        let status = PostRunHook.run(
            command: "true",
            environment: [:],
            shellPath: "/nonexistent/shell",
        )
        #expect(status == nil)
    }

    @Test func environmentIncludesReportCounts() {
        var report = BackupReport()
        report.uploaded = 5
        report.failed = 2
        report.skipped = 100
        report.totalBytes = 1234

        let env = PostRunHook.environment(result: "failure", report: report)

        #expect(env == [
            "ATTIC_RESULT": "failure",
            "ATTIC_UPLOADED": "5",
            "ATTIC_FAILED": "2",
            "ATTIC_SKIPPED": "100",
            "ATTIC_TOTAL_BYTES": "1234",
        ])
    }

    @Test func environmentWithoutReportOnlyCarriesResult() {
        #expect(PostRunHook.environment(result: "failure", report: nil) == ["ATTIC_RESULT": "failure"])
    }
}
