@testable import AtticCLI
@testable import AtticCore
import Foundation
import LadderKit
import Testing

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }

    func values() -> [String] {
        lock.withLock { storage }
    }
}

private func parseJSONLines(_ lines: [String]) throws -> [[String: Any]] {
    try lines.map { line in
        #expect(!line.contains("\u{1B}"))
        #expect(!line.contains("IMG_"))
        return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

private func makeJSONDelegate(
    lines: LockedLines,
    diagnostics: LockedLines? = nil,
) -> BackupJSONProgressDelegate {
    BackupJSONProgressDelegate(
        output: { lines.append($0) },
        diagnostics: { diagnostics?.append($0) },
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
    )
}

struct BackupJSONProgressTests {
    @Test func startedEventHasStableRequiredState() throws {
        let lines = LockedLines()
        let progress = makeJSONDelegate(lines: lines)

        progress.backupStarted(pending: 3, photos: 2, videos: 1)

        let events = try parseJSONLines(lines.values())
        let event = try #require(events.first)
        #expect(event["schema_version"] as? Int == 1)
        #expect(event["event"] as? String == "started")
        #expect(event["timestamp"] as? String == "2023-11-14T22:13:20.000Z")
        #expect(event["percentage"] as? Double == 0)
        let counts = try #require(event["counts"] as? [String: Any])
        #expect(counts["total"] as? Int == 3)
        #expect(counts["photos"] as? Int == 2)
        #expect(counts["videos"] as? Int == 1)
        #expect(counts["completed"] as? Int == 0)
        #expect(counts["uploaded"] as? Int == 0)
        #expect(counts["failed"] as? Int == 0)
        #expect(counts["skipped"] as? Int == 0)
        let bytes = try #require(event["bytes"] as? [String: Any])
        #expect(bytes["uploaded"] as? Int == 0)
        let pause = try #require(event["pause"] as? [String: Any])
        #expect(pause["paused"] as? Bool == false)
        let concurrency = try #require(event["concurrency"] as? [String: Any])
        #expect(concurrency["limit"] is NSNull)
        #expect(event["final"] == nil)
    }

    @Test func concurrentCallbacksProduceWholeParseableLinesAndAccurateFinalCounts() throws {
        let lines = LockedLines()
        let progress = makeJSONDelegate(lines: lines)
        progress.backupStarted(pending: 100, photos: 100, videos: 0)

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            progress.assetUploaded(
                uuid: "private-uuid-\(index)",
                filename: "IMG_PRIVATE_\(index).HEIC",
                type: .photo,
                size: 10,
            )
        }
        var report = BackupReport()
        report.uploaded = 100
        report.totalBytes = 1000
        progress.finish(report: report, dryRun: false)

        let events = try parseJSONLines(lines.values())
        #expect(events.count == 102)
        #expect(events.filter { $0["event"] as? String == "completed" }.count == 1)
        let final = try #require(events.last)
        let counts = try #require(final["counts"] as? [String: Any])
        #expect(counts["completed"] as? Int == 100)
        #expect(counts["uploaded"] as? Int == 100)
        let bytes = try #require(final["bytes"] as? [String: Any])
        #expect(bytes["uploaded"] as? Int == 1000)
        #expect(final["percentage"] as? Double == 100)
        let result = try #require(final["final"] as? [String: Any])
        #expect(result["result"] as? String == "success")
        #expect(result["exit_classification"] as? String == "success")
        #expect(result["dry_run"] as? Bool == false)
        let joined = lines.values().joined(separator: "\n")
        #expect(!joined.contains("private-uuid"))
        #expect(!joined.contains("IMG_PRIVATE"))
    }

    @Test func pauseResumeRetryAndConcurrencyUseBoundedMetadata() throws {
        let lines = LockedLines()
        let progress = makeJSONDelegate(lines: lines)
        progress.backupStarted(pending: 1, photos: 1, videos: 0)
        progress.concurrencyChanged(limit: 4)
        progress.backupPaused(reason: "provider said /secret/path failed")
        progress.assetRetrying(
            uuid: "private-uuid",
            filename: "IMG_PRIVATE.HEIC",
            attempt: 2,
            maxAttempts: 5,
        )
        progress.backupResumed()

        let events = try parseJSONLines(lines.values())
        #expect(events.map { $0["event"] as? String } == [
            "started", "concurrency_changed", "paused", "retrying", "resumed",
        ])
        let changed = try #require(events[1]["concurrency"] as? [String: Any])
        #expect(changed["limit"] as? Int == 4)
        let paused = try #require(events[2]["pause"] as? [String: Any])
        #expect(paused["paused"] as? Bool == true)
        let retry = try #require(events[3]["retry"] as? [String: Any])
        #expect(retry["attempt"] as? Int == 2)
        #expect(retry["max_attempts"] as? Int == 5)
        let resumed = try #require(events[4]["pause"] as? [String: Any])
        #expect(resumed["paused"] as? Bool == false)
        #expect(!lines.values().joined().contains("secret"))
    }

    @Test func partialFailureOmitsFilenameAndRawError() throws {
        let lines = LockedLines()
        let progress = makeJSONDelegate(lines: lines)
        progress.backupStarted(pending: 2, photos: 2, videos: 0)
        progress.assetUploaded(uuid: "one", filename: "IMG_ONE.HEIC", type: .photo, size: 20)
        progress.assetFailed(
            uuid: "two",
            filename: "IMG_TWO.HEIC",
            message: "raw provider error /Users/private/file",
            classification: .permanentlyUnavailable,
        )
        var report = BackupReport()
        report.uploaded = 1
        report.failed = 1
        report.totalBytes = 20
        progress.finish(report: report, dryRun: false)

        let events = try parseJSONLines(lines.values())
        let final = try #require(events.last)
        let result = try #require(final["final"] as? [String: Any])
        #expect(result["result"] as? String == "failure")
        #expect(result["exit_classification"] as? String == "partial_failure")
        let output = lines.values().joined(separator: "\n")
        #expect(!output.contains("IMG_TWO"))
        #expect(!output.contains("provider error"))
        #expect(!output.contains("/Users/private"))
    }

    @Test func dryRunAndEmptyRunsCompleteExactlyOnce() throws {
        let dryRunLines = LockedLines()
        let dryRun = makeJSONDelegate(lines: dryRunLines)
        dryRun.backupStarted(pending: 2, photos: 1, videos: 1)
        dryRun.backupCompleted(uploaded: 0, failed: 0, totalBytes: 0)
        var report = BackupReport()
        report.skipped = 2
        dryRun.finish(report: report, dryRun: true)
        dryRun.finish(report: report, dryRun: true)

        let dryEvents = try parseJSONLines(dryRunLines.values())
        #expect(dryEvents.filter { $0["event"] as? String == "completed" }.count == 1)
        let final = try #require(dryEvents.last)
        let counts = try #require(final["counts"] as? [String: Any])
        #expect(counts["skipped"] as? Int == 2)
        #expect(counts["completed"] as? Int == 2)
        #expect(final["percentage"] as? Double == 100)

        let emptyLines = LockedLines()
        let empty = makeJSONDelegate(lines: emptyLines)
        empty.finish(report: BackupReport(), dryRun: false)
        let emptyEvents = try parseJSONLines(emptyLines.values())
        #expect(emptyEvents.count == 1)
        #expect(emptyEvents[0]["event"] as? String == "completed")
        #expect(emptyEvents[0]["percentage"] as? Double == 100)
    }

    @Test func failureDetailsAndPipelineDiagnosticsGoToStderrSink() {
        let lines = LockedLines()
        let diagnostics = LockedLines()
        let progress = makeJSONDelegate(lines: lines, diagnostics: diagnostics)
        progress.backupStarted(pending: 1, photos: 1, videos: 0)
        progress.assetFailed(
            uuid: "private-uuid",
            filename: "IMG_PRIVATE.HEIC",
            message: "raw provider error",
            classification: .other,
        )
        progress.diagnostic(message: "Manifest save failed: provider detail")

        let stdout = lines.values().joined(separator: "\n")
        let stderr = diagnostics.values().joined(separator: "\n")
        #expect(!stdout.contains("IMG_PRIVATE"))
        #expect(!stdout.contains("provider"))
        #expect(stderr.contains("IMG_PRIVATE.HEIC: raw provider error"))
        #expect(stderr.contains("Manifest save failed: provider detail"))
    }

    @Test func fatalAndCancellationCompletionAreClassifiedWithoutErrorText() throws {
        let fatalLines = LockedLines()
        let fatal = makeJSONDelegate(lines: fatalLines)
        fatal.finishFatal(cancelled: false)
        fatal.finishFatal(cancelled: false)

        let fatalEvents = try parseJSONLines(fatalLines.values())
        #expect(fatalEvents.count == 1)
        let fatalResult = try #require(fatalEvents[0]["final"] as? [String: Any])
        #expect(fatalResult["result"] as? String == "failure")
        #expect(fatalResult["exit_classification"] as? String == "fatal_failure")

        let cancelledLines = LockedLines()
        let cancelled = makeJSONDelegate(lines: cancelledLines)
        cancelled.backupStarted(pending: 1, photos: 1, videos: 0)
        cancelled.finishFatal(cancelled: true)
        let cancelledEvents = try parseJSONLines(cancelledLines.values())
        let cancelledResult = try #require(cancelledEvents.last?["final"] as? [String: Any])
        #expect(cancelledResult["result"] as? String == "cancelled")
        #expect(cancelledResult["exit_classification"] as? String == "cancelled")
    }
}
