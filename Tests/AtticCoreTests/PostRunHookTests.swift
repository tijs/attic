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

    @Test func terminatesHungHookAfterTimeout() {
        let clock = ContinuousClock()
        let start = clock.now

        let status = PostRunHook.run(command: "sleep 30", environment: [:], timeout: 0.5)

        #expect(status == nil)
        #expect(clock.now - start < .seconds(10))
    }

    @Test func timeoutTerminatesDescendantProcesses() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var childPID: pid_t = 0
        defer {
            try? FileManager.default.removeItem(at: pidFile)
            if childPID > 0 {
                kill(childPID, SIGKILL)
            }
        }

        let status = PostRunHook.run(
            command: "sh -c 'trap \"\" HUP TERM; exec sleep 30' & echo $! > \"$PID_FILE\"; wait",
            environment: ["PID_FILE": pidFile.path],
            timeout: 0.5,
        )

        #expect(status == nil)
        childPID =
            try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let descendantIsGone = kill(childPID, 0) == -1 && errno == ESRCH
        #expect(descendantIsGone)
        if descendantIsGone {
            childPID = 0
        }
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
