import AtticCore
import Foundation
import LadderKit

/// Machine-readable backup progress as independently parseable JSON Lines.
///
/// All state mutation, encoding, and output are serialized under one lock so
/// concurrent pipeline callbacks can never interleave bytes on stdout.
final class BackupJSONProgressDelegate: BackupProgressDelegate, @unchecked Sendable {
    typealias Output = @Sendable (String) -> Void
    typealias Diagnostics = @Sendable (String) -> Void
    typealias Clock = @Sendable () -> Date

    private struct State {
        var total = 0
        var photos = 0
        var videos = 0
        var uploaded = 0
        var failed = 0
        var skipped = 0
        var uploadedBytes = 0
        var paused = false
        var concurrencyLimit: Int?
        var finished = false
    }

    private let lock = NSLock()
    private let output: Output
    private let diagnostics: Diagnostics
    private let now: Clock
    private var state = State()

    init(
        output: @escaping Output = { line in
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        },
        diagnostics: @escaping Diagnostics = { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        },
        now: @escaping Clock = Date.init,
    ) {
        self.output = output
        self.diagnostics = diagnostics
        self.now = now
    }

    func backupStarted(pending: Int, photos: Int, videos: Int) {
        emit(event: "started") { state in
            state.total = pending
            state.photos = photos
            state.videos = videos
        }
    }

    func batchStarted(batchNumber: Int, totalBatches: Int, assetCount: Int) {
        emit(
            event: "batch_started",
            extra: [
                "batch": [
                    "number": batchNumber,
                    "total": totalBatches,
                    "assets": assetCount,
                ],
            ],
        )
    }

    func assetStarting(uuid: String, filename: String, size: Int) {
        emit(event: "asset_started")
    }

    func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int) {
        emit(event: "progress") { state in
            state.uploaded += 1
            state.uploadedBytes += size
        }
    }

    func assetRetrying(uuid: String, filename: String, attempt: Int, maxAttempts: Int) {
        emit(
            event: "retrying",
            extra: [
                "retry": [
                    "attempt": attempt,
                    "max_attempts": maxAttempts,
                ],
            ],
        )
    }

    func assetFailed(uuid: String, filename: String, message: String, classification: ExportClassification) {
        lock.withLock {
            guard !state.finished else { return }
            diagnostics("Backup asset failed: \(filename): \(message)")
            state.failed += 1
            write(event: "progress", state: state, extra: [:])
        }
    }

    func diagnostic(message: String) {
        lock.withLock {
            guard !state.finished else { return }
            diagnostics(message)
        }
    }

    func manifestSaved(entriesCount: Int) {
        emit(event: "manifest_saved")
    }

    func backupPaused(reason: String) {
        emit(event: "paused") { state in
            state.paused = true
        }
    }

    func backupResumed() {
        emit(event: "resumed") { state in
            state.paused = false
        }
    }

    func concurrencyChanged(limit: Int) {
        emit(event: "concurrency_changed") { state in
            state.concurrencyLimit = limit
        }
    }

    /// The pipeline callback lacks skipped/final-result information, so the
    /// command emits the single completion event through ``finish(report:dryRun:)``.
    func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int) {
        lock.withLock {
            guard !state.finished else { return }
            state.uploaded = uploaded
            state.failed = failed
            state.uploadedBytes = totalBytes
        }
    }

    func finish(report: BackupReport, dryRun: Bool) {
        finish(
            report: report,
            result: report.failed == 0 ? "success" : "failure",
            exitClassification: report.failed == 0 ? "success" : "partial_failure",
            dryRun: dryRun,
        )
    }

    func finishFatal(cancelled: Bool) {
        finish(
            report: nil,
            result: cancelled ? "cancelled" : "failure",
            exitClassification: cancelled ? "cancelled" : "fatal_failure",
            dryRun: false,
        )
    }

    private func emit(
        event: String,
        extra: [String: Any] = [:],
        update: (inout State) -> Void = { _ in },
    ) {
        lock.withLock {
            guard !state.finished else { return }
            update(&state)
            write(event: event, state: state, extra: extra)
        }
    }

    private func finish(
        report: BackupReport?,
        result: String,
        exitClassification: String,
        dryRun: Bool,
    ) {
        lock.withLock {
            guard !state.finished else { return }
            if let report {
                state.uploaded = report.uploaded
                state.failed = report.failed
                state.skipped = report.skipped
                state.uploadedBytes = report.totalBytes
                if state.total == 0 {
                    state.total = report.uploaded + report.failed + report.skipped
                }
            }
            state.paused = false
            state.finished = true
            write(
                event: "completed",
                state: state,
                extra: [
                    "final": [
                        "result": result,
                        "exit_classification": exitClassification,
                        "dry_run": dryRun,
                    ],
                ],
            )
        }
    }

    private func write(event: String, state: State, extra: [String: Any]) {
        let completed = state.uploaded + state.failed + state.skipped
        let percentage: Double = if event == "completed", state.total == 0 {
            100
        } else if state.total > 0 {
            min(100, Double(completed) * 100 / Double(state.total))
        } else {
            0
        }

        var object: [String: Any] = [
            "schema_version": 1,
            "event": event,
            "timestamp": Self.timestamp(now()),
            "counts": [
                "total": state.total,
                "photos": state.photos,
                "videos": state.videos,
                "completed": completed,
                "uploaded": state.uploaded,
                "failed": state.failed,
                "skipped": state.skipped,
            ],
            "bytes": ["uploaded": state.uploadedBytes],
            "percentage": percentage,
            "pause": ["paused": state.paused],
            "concurrency": ["limit": state.concurrencyLimit.map { $0 as Any } ?? NSNull()],
        ]
        object.merge(extra) { _, new in new }

        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else { return }
        output(line)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
