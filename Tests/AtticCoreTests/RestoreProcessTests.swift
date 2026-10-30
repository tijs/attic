@testable import AtticCLI
@testable import AtticCore
import Darwin
import Foundation
import Testing

struct RestoreProcessTests {
    @Test func capturesOutputAndNonzeroStatusWithoutRunLoopWaits() async throws {
        let result = try await RestoreProcess.run(
            "/bin/sh", arguments: ["-c", "printf stdout; printf stderr >&2; exit 7"], timeout: 2,
        )
        #expect(result.status == 7)
        #expect(result.output == "stdoutstderr")
    }

    @Test func timeoutKillsAndReapsChildAndItsDescendants() async throws {
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = ProcessInfo.processInfo.systemUptime
        await #expect(throws: RestoreError.self) {
            try await RestoreProcess.run(
                "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \"$1/parent\"; sleep 30 & echo $! > \"$1/child\"; wait",
                    "fixture",
                    root.path,
                ],
                timeout: 0.3,
            )
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 3)
        let parent = try pid(root.appendingPathComponent("parent"))
        let child = try pid(root.appendingPathComponent("child"))
        #expect(kill(parent, 0) == -1 && errno == ESRCH)
        // launchd may need a moment to reap the killed descendant.
        for _ in 0 ..< 100 where kill(child, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(child, 0) == -1 && errno == ESRCH)
    }

    @Test func cancellationReturnsPromptlyAndReapsChild() async throws {
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("pid")
        let task = Task {
            try await RestoreProcess.run(
                "/bin/sh", arguments: ["-c", "echo $$ > \"$1\"; exec sleep 30", "fixture", file.path], timeout: 30,
            )
        }
        for _ in 0 ..< 200 where !FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let processID = try pid(file)
        let started = ProcessInfo.processInfo.systemUptime
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ProcessInfo.processInfo.systemUptime - started < 3)
        #expect(kill(processID, 0) == -1 && errno == ESRCH)
    }

    @Test func rejectsExcessOutputAndInvalidEncodingAndLaunchFailure() async {
        await #expect(throws: RestoreError.self) {
            try await RestoreProcess.run("/usr/bin/yes", arguments: [], timeout: 2)
        }
        await #expect(throws: RestoreError.self) {
            try await RestoreProcess.run("/bin/sh", arguments: ["-c", "printf '\\377'"], timeout: 2)
        }
        await #expect(throws: RestoreError.self) {
            try await RestoreProcess.run("/nonexistent-attic-fixture", arguments: [], timeout: 2)
        }
    }

    private func pid(_ file: URL) throws -> pid_t {
        try #require(Int32(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
