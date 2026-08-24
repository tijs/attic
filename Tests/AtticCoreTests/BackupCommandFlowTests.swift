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

@Suite(.serialized)
struct BackupCommandFlowTests {
    @Test func signalBeforeBackupTaskCreationIsRememberedAndEmitsCancelledJSON() throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/AtticCLI")
            .path
        let script = """
        import json, os, select, signal, subprocess, sys, time
        env = dict(
            os.environ,
            ATTIC_TEST_BLOCKING_BACKUP="1",
            ATTIC_TEST_SIGNAL_ARM_DELAY="1")
        process = subprocess.Popen(
            [sys.argv[1], "backup", "--json"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, text=True)
        stderr = ""
        deadline = time.time() + 5
        marker = "ATTIC_TEST_SIGNAL_HANDLERS_INSTALLED"
        while marker not in stderr and time.time() < deadline:
            ready, _, _ = select.select([process.stderr], [], [], 0.1)
            if ready:
                stderr += process.stderr.readline()
        if marker not in stderr:
            process.kill()
            raise SystemExit("signal handlers did not become ready: " + repr(stderr))
        os.kill(process.pid, signal.SIGTERM)
        try:
            stdout, remaining_stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            raise SystemExit("backup did not stop after pre-task signal")
        stderr += remaining_stderr
        events = [json.loads(line) for line in stdout.splitlines() if line]
        completed = [event for event in events if event.get("event") == "completed"]
        if len(completed) != 1:
            raise SystemExit("expected one completed event: " + repr(stdout))
        final = completed[0].get("final", {})
        if final.get("result") != "cancelled" or final.get("exit_classification") != "cancelled":
            raise SystemExit("unexpected final event: " + repr(completed[0]))
        if process.returncode == 0:
            raise SystemExit("pre-task cancellation unexpectedly exited zero")
        print("ATTIC_PRETASK_SIGNAL_TEST_COMPLETED", json.dumps(completed[0], sort_keys=True))
        """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, executable]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let transcript = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8,
        ) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: transcript))
        #expect(transcript.contains("ATTIC_PRETASK_SIGNAL_TEST_COMPLETED"))
    }

    @Test func realSIGINTAndSIGTERMCancelBlockingBackupAndEmitOneFinalJSONEvent() throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/AtticCLI")
            .path
        #expect(FileManager.default.isExecutableFile(atPath: executable))

        for signalName in ["SIGINT", "SIGTERM"] {
            let script = """
            import json, os, select, signal, subprocess, sys, time
            env = dict(os.environ, ATTIC_TEST_BLOCKING_BACKUP="1")
            process = subprocess.Popen(
                [sys.argv[1], "backup", "--json"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=env, text=True)
            stderr = ""
            deadline = time.time() + 5
            while "ATTIC_TEST_BACKUP_READY" not in stderr and time.time() < deadline:
                ready, _, _ = select.select([process.stderr], [], [], 0.1)
                if ready:
                    stderr += process.stderr.readline()
            if "ATTIC_TEST_BACKUP_READY" not in stderr:
                process.kill()
                raise SystemExit("blocking backup did not become ready")
            os.kill(process.pid, getattr(signal, sys.argv[2]))
            try:
                stdout, remaining_stderr = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                raise SystemExit("backup did not stop after " + sys.argv[2])
            stderr += remaining_stderr
            events = [json.loads(line) for line in stdout.splitlines() if line]
            completed = [event for event in events if event.get("event") == "completed"]
            if len(completed) != 1:
                raise SystemExit("expected one completed event: " + repr(stdout))
            final = completed[0].get("final", {})
            if final.get("result") != "cancelled" or final.get("exit_classification") != "cancelled":
                raise SystemExit("unexpected final event: " + repr(completed[0]))
            if process.returncode == 0:
                raise SystemExit("signal cancellation unexpectedly exited zero")
            print("ATTIC_SIGNAL_TEST_COMPLETED", sys.argv[2], json.dumps(completed[0], sort_keys=True))
            """
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", script, executable, signalName]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()

            let transcript = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8,
            ) ?? ""
            #expect(process.terminationStatus == 0, Comment(rawValue: transcript))
            #expect(transcript.contains("ATTIC_SIGNAL_TEST_COMPLETED \(signalName)"))
            #expect(transcript.components(separatedBy: "\"event\": \"completed\"").count - 1 == 1)
            #expect(transcript.contains("\"exit_classification\": \"cancelled\""))
        }
    }

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
