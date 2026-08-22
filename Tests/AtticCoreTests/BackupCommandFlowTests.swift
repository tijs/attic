import ArgumentParser
@testable import AtticCLI
@testable import AtticCore
import Foundation
import Testing

private final class BackupFlowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var hooks: [String] = []

    func appendLine(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    func appendHook(_ hook: String) {
        lock.withLock { hooks.append(hook) }
    }

    func snapshot() -> (lines: [String], hooks: [String]) {
        lock.withLock { (lines, hooks) }
    }
}

private func finalClassification(_ lines: [String]) throws -> String {
    let line = try #require(lines.last)
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
    )
    let final = try #require(object["final"] as? [String: Any])
    return try #require(final["exit_classification"] as? String)
}

struct BackupCommandFlowTests {
    @Test func parserAcceptsJSONFlagWithoutChangingStatusJSON() throws {
        let command = try BackupCommand.parse(["--json"])
        #expect(command.json)
        #expect(!command.dryRun)
    }

    @Test func successfulFlowCompletesJSONBeforeSuccessHook() async throws {
        let recorder = BackupFlowRecorder()
        let progress = BackupJSONProgressDelegate(
            output: { recorder.appendLine($0) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
        )
        let report: BackupReport = {
            var report = BackupReport()
            report.uploaded = 2
            report.totalBytes = 40
            return report
        }()

        try await BackupCommand.performBackup(
            dryRun: false,
            jsonProgress: progress,
            execute: { report },
            successHook: { _ in recorder.appendHook("success") },
            failureHook: { _ in recorder.appendHook("failure") },
        )

        let snapshot = recorder.snapshot()
        #expect(try finalClassification(snapshot.lines) == "success")
        #expect(snapshot.hooks == ["success"])
    }

    @Test func partialFailureCompletesJSONRunsFailureHookAndExitsNonZero() async throws {
        let recorder = BackupFlowRecorder()
        let progress = BackupJSONProgressDelegate(output: { recorder.appendLine($0) })
        let report: BackupReport = {
            var report = BackupReport()
            report.uploaded = 1
            report.failed = 1
            report.totalBytes = 20
            return report
        }()

        await #expect(throws: ExitCode.self) {
            try await BackupCommand.performBackup(
                dryRun: false,
                jsonProgress: progress,
                execute: { report },
                successHook: { _ in recorder.appendHook("success") },
                failureHook: { _ in recorder.appendHook("failure") },
            )
        }

        let snapshot = recorder.snapshot()
        #expect(try finalClassification(snapshot.lines) == "partial_failure")
        #expect(snapshot.hooks == ["failure"])
    }

    @Test func fatalSetupFailureCompletesJSONOnceAndPreservesThrownError() async throws {
        struct SetupError: Error {}
        let recorder = BackupFlowRecorder()
        let progress = BackupJSONProgressDelegate(output: { recorder.appendLine($0) })

        await #expect(throws: SetupError.self) {
            try await BackupCommand.performBackup(
                dryRun: false,
                jsonProgress: progress,
                execute: { throw SetupError() },
                successHook: { _ in recorder.appendHook("success") },
                failureHook: { report in
                    #expect(report == nil)
                    recorder.appendHook("failure")
                },
            )
        }

        let snapshot = recorder.snapshot()
        #expect(snapshot.lines.count == 1)
        #expect(try finalClassification(snapshot.lines) == "fatal_failure")
        #expect(snapshot.hooks == ["failure"])
    }

    @Test func cancellationHasBoundedClassificationAndPreservesCancellation() async throws {
        let recorder = BackupFlowRecorder()
        let progress = BackupJSONProgressDelegate(output: { recorder.appendLine($0) })

        await #expect(throws: CancellationError.self) {
            try await BackupCommand.performBackup(
                dryRun: false,
                jsonProgress: progress,
                execute: { throw CancellationError() },
                successHook: { _ in recorder.appendHook("success") },
                failureHook: { _ in recorder.appendHook("failure") },
            )
        }

        let snapshot = recorder.snapshot()
        #expect(try finalClassification(snapshot.lines) == "cancelled")
        #expect(snapshot.hooks == ["failure"])
    }

    @Test func JSONHookCommandRoutesHookOutputToStderr() {
        #expect(
            BackupCommand.hookCommand("printf hello", json: true)
                == "exec 1>&2; printf hello",
        )
        #expect(BackupCommand.hookCommand("printf hello", json: false) == "printf hello")
    }
}
