import AtticCore
import Foundation
import LadderKit

protocol TerminalSessionControlling: Sendable {
    func begin()
    func end()
}

/// The renderer deliberately leaves stdin modes unchanged and keeps the cursor
/// below every complete frame. A SIGINT/SIGTERM therefore cannot strand the
/// user's terminal in raw/no-echo mode or leave its cursor inside the frame.
private struct InterruptSafeTerminalSession: TerminalSessionControlling {
    func begin() {}
    func end() {}
}

/// ANSI live-updating dashboard for backup progress.
///
/// Every callback mutates state, takes an immutable frame snapshot, and writes
/// the complete ANSI redraw while holding one lock. This prevents concurrent
/// upload callbacks and timer ticks from interleaving terminal bytes.
final class TerminalRenderer: BackupProgressDelegate, @unchecked Sendable {
    typealias Output = @Sendable (String) -> Void
    typealias Clock = @Sendable () -> Date
    typealias TerminalWidth = @Sendable () -> Int

    private struct Failure {
        let filename: String
        let message: String
        let classification: ExportClassification
    }

    private struct RenderState {
        var total = 0
        var uploaded = 0
        var failed = 0
        var totalBytes = 0
        var currentFile = ""
        var uploadedPhotos = 0
        var uploadedVideos = 0
        var isPaused = false
        var pauseReason = ""
        var pauseStarted: Date?
        var totalPauseDuration: TimeInterval = 0
        var failedAssets: [Failure] = []
        var diagnostics: [String] = []
        var concurrencyLimit: Int?
        var startTime: Date?
    }

    private struct FrameSnapshot {
        let lines: [String]
    }

    private let lock = NSLock()
    private let spinner: PreparationSpinner?
    private let output: Output
    private let now: Clock
    private let terminalWidth: TerminalWidth
    private let terminalSession: any TerminalSessionControlling
    private let tickInterval: Duration?
    private var state = RenderState()
    private var renderedHeight = 0
    private var terminalActive = false
    private var completed = false
    private var tickTask: Task<Void, Never>?

    init(
        spinner: PreparationSpinner? = nil,
        output: @escaping Output = { chunk in
            FileHandle.standardOutput.write(Data(chunk.utf8))
        },
        now: @escaping Clock = Date.init,
        terminalWidth: @escaping TerminalWidth = terminalColumnCount,
        terminalSession: any TerminalSessionControlling = InterruptSafeTerminalSession(),
        tickInterval: Duration? = .seconds(1),
    ) {
        self.spinner = spinner
        self.output = output
        self.now = now
        self.terminalWidth = terminalWidth
        self.terminalSession = terminalSession
        self.tickInterval = tickInterval
    }

    deinit {
        tickTask?.cancel()
        terminalSession.end()
    }

    func backupStarted(pending: Int, photos: Int, videos: Int) {
        spinner?.stop()
        lock.withLock {
            guard !completed else { return }
            terminalSession.begin()
            terminalActive = true
            state.total = pending
            state.startTime = now()
            renderLiveLocked()
            startTickLocked()
        }
    }

    func batchStarted(batchNumber: Int, totalBatches: Int, assetCount: Int) {
        renderAfterUpdate { _ in }
    }

    func assetStarting(uuid: String, filename: String, size: Int) {
        renderAfterUpdate { state in
            state.currentFile = "\(filename) (\(formatBytes(size)))"
        }
    }

    func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int) {
        renderAfterUpdate { state in
            state.uploaded += 1
            state.totalBytes += size
            state.currentFile = "\(filename) (\(formatBytes(size)))"
            if type == .photo {
                state.uploadedPhotos += 1
            } else {
                state.uploadedVideos += 1
            }
        }
    }

    func assetRetrying(uuid: String, filename: String, attempt: Int, maxAttempts: Int) {
        renderAfterUpdate { state in
            state.currentFile = "\(filename) — retry \(attempt)/\(maxAttempts)"
        }
    }

    func assetFailed(uuid: String, filename: String, message: String, classification: ExportClassification) {
        renderAfterUpdate { state in
            state.failed += 1
            state.currentFile = "\(filename) — \(message)"
            if state.failedAssets.count < 50 {
                state.failedAssets.append(Failure(
                    filename: filename,
                    message: message,
                    classification: classification,
                ))
            }
        }
    }

    func manifestSaved(entriesCount: Int) {}

    func backupPaused(reason: String) {
        renderAfterUpdate { state in
            state.isPaused = true
            state.pauseReason = reason
            state.pauseStarted = now()
        }
    }

    func backupResumed() {
        renderAfterUpdate { state in
            state.isPaused = false
            if let pauseStarted = state.pauseStarted {
                state.totalPauseDuration += now().timeIntervalSince(pauseStarted)
            }
            state.pauseStarted = nil
            state.pauseReason = ""
        }
    }

    func concurrencyChanged(limit: Int) {
        renderAfterUpdate { state in
            state.concurrencyLimit = limit
        }
    }

    func diagnostic(message: String) {
        renderAfterUpdate { state in
            if state.diagnostics.count < 20 {
                state.diagnostics.append(message)
            }
            state.currentFile = "Warning: \(message)"
        }
    }

    func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int) {
        lock.withLock {
            guard !completed else { return }
            completed = true
            tickTask?.cancel()
            tickTask = nil
            state.uploaded = uploaded
            state.failed = failed
            state.totalBytes = totalBytes
            state.currentFile = ""
            let snapshot = finalSnapshot(state: state, at: now(), width: terminalWidth())
            writeLocked(snapshot)
            restoreTerminalLocked()
        }
    }

    /// Restore terminal state when the pipeline exits without a completion
    /// callback, including thrown errors and cooperative cancellation.
    func finish() {
        lock.withLock {
            completed = true
            tickTask?.cancel()
            tickTask = nil
            restoreTerminalLocked()
        }
    }

    private func renderAfterUpdate(_ update: (inout RenderState) -> Void) {
        lock.withLock {
            guard !completed else { return }
            update(&state)
            renderLiveLocked()
        }
    }

    private func renderLiveLocked() {
        let snapshot = liveSnapshot(state: state, at: now(), width: terminalWidth())
        writeLocked(snapshot)
    }

    private func startTickLocked() {
        guard tickTask == nil, let tickInterval else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard !Task.isCancelled else { break }
                self?.renderAfterUpdate { _ in }
            }
        }
    }

    private func restoreTerminalLocked() {
        guard terminalActive else { return }
        terminalSession.end()
        terminalActive = false
    }

    private func writeLocked(_ snapshot: FrameSnapshot) {
        let newHeight = snapshot.lines.count
        let rowsToRewrite = max(renderedHeight, newHeight)
        var chunk = ""
        if renderedHeight > 0 {
            chunk += "\u{1B}[\(renderedHeight)A"
        }
        for row in 0 ..< rowsToRewrite {
            chunk += "\u{1B}[2K"
            if row < newHeight {
                chunk += snapshot.lines[row]
            }
            chunk += "\n"
        }
        if rowsToRewrite > newHeight {
            chunk += "\u{1B}[\(rowsToRewrite - newHeight)A"
        }
        renderedHeight = newHeight
        output(chunk)
    }

    private func liveSnapshot(state: RenderState, at date: Date, width: Int) -> FrameSnapshot {
        let columns = max(1, width)
        let elapsed = activeElapsed(state: state, at: date)
        let speed = elapsed > 0 ? Double(state.totalBytes) / elapsed : 0
        let completed = state.uploaded + state.failed
        let barWidth = max(5, min(30, columns - 25))
        let filled = state.total > 0 ? min(barWidth, (completed * barWidth) / state.total) : 0
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)
        let speedText = state.isPaused ? "—" : "\(formatBytes(Int(speed)))/s"
        let lanes = state.concurrencyLimit.map { "  ·  \($0) lane\($0 == 1 ? "" : "s")" } ?? ""

        let status: String
        if state.isPaused, let pauseStarted = state.pauseStarted {
            let plain = fit(
                "  Status    ⏸ \(state.pauseReason) (\(formatDuration(date.timeIntervalSince(pauseStarted))))",
                width: columns,
            )
            status = "\u{1B}[33m\(plain)\u{1B}[0m"
        } else {
            status = fit("  Current   \(state.currentFile)", width: columns)
        }

        return FrameSnapshot(lines: [
            "",
            fit("  Progress  [\(bar)] \(completed)/\(state.total)", width: columns),
            fit("  Photos    \(state.uploadedPhotos) uploaded", width: columns),
            fit("  Videos    \(state.uploadedVideos) uploaded", width: columns),
            fit("  Speed     \(speedText)\(lanes)", width: columns),
            fit("  Errors    \(state.failed)", width: columns),
            "",
            status,
            fit("  Elapsed   \(formatDuration(elapsed))", width: columns),
        ])
    }

    private func finalSnapshot(state: RenderState, at date: Date, width: Int) -> FrameSnapshot {
        let columns = max(1, width)
        let elapsed = activeElapsed(state: state, at: date)
        let speed = elapsed > 0 ? Double(state.totalBytes) / elapsed : 0
        let status = state.failed > 0
            ? "Completed with \(state.failed) error\(state.failed == 1 ? "" : "s")"
            : "Complete"
        let completionLine = fit(
            "  ✓ \(status) — \(formatBytes(state.totalBytes)) in \(formatDuration(elapsed))",
            width: columns,
        ).replacingOccurrences(of: "✓", with: "\u{1B}[32m✓\u{1B}[0m")
        var lines = [
            completionLine,
            fit("  Photos    \(state.uploadedPhotos) uploaded", width: columns),
            fit("  Videos    \(state.uploadedVideos) uploaded", width: columns),
            fit("  Speed     \(formatBytes(Int(speed)))/s avg", width: columns),
            fit("  Errors    \(state.failed)", width: columns),
        ]

        if !state.diagnostics.isEmpty {
            lines.append("")
            lines += state.diagnostics.map { fit("  Warning: \($0)", width: columns) }
        }

        if state.failed > 0 {
            lines += ["", fit("  Failed assets:", width: columns)]
            var permanentCount = 0
            for failure in state.failedAssets {
                let suffix = failure.classification == .permanentlyUnavailable
                    ? " (permanently unavailable)"
                    : ""
                lines.append(fit("  ✗ \(failure.filename): \(failure.message)\(suffix)", width: columns))
                if failure.classification == .permanentlyUnavailable {
                    permanentCount += 1
                }
            }
            if state.failed > state.failedAssets.count {
                lines.append(fit("  ... and \(state.failed - state.failedAssets.count) more", width: columns))
            }
            lines.append("")
            let retryableCount = state.failedAssets.count - permanentCount
            if permanentCount > 0, retryableCount == 0 {
                lines += wrap(
                    "Note: These assets are permanently unavailable from iCloud "
                        + "(typically shared-album originals iCloud cannot deliver, "
                        + "or assets removed from the source library). They've been "
                        + "recorded in `~/.attic/unavailable-assets.json` and will "
                        + "be skipped on future runs.",
                    width: columns,
                )
            } else if permanentCount > 0 {
                lines += wrap(
                    "Note: \(permanentCount) asset(s) are permanently unavailable "
                        + "from iCloud (recorded in `~/.attic/unavailable-assets.json` "
                        + "and skipped on future runs). The remaining \(retryableCount) "
                        + "failure(s) are retryable — run `attic backup` again to retry.",
                    width: columns,
                )
            } else {
                lines.append(fit("Tip: Run `attic backup` again to retry failed assets.", width: columns))
            }
        }
        return FrameSnapshot(lines: lines)
    }

    private func activeElapsed(state: RenderState, at date: Date) -> TimeInterval {
        guard let startTime = state.startTime else { return 0 }
        let currentPause = state.pauseStarted.map { date.timeIntervalSince($0) } ?? 0
        return max(0, date.timeIntervalSince(startTime) - state.totalPauseDuration - currentPause)
    }
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
}

private func terminalColumnCount() -> Int {
    if let columns = ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init), columns > 0 {
        return columns
    }

    var size = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
        return Int(size.ws_col)
    }
    return 100
}

private func fit(_ value: String, width: Int) -> String {
    guard width > 0 else { return "" }
    let singleLine = value
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    guard singleLine.count > width else { return singleLine }
    guard width > 1 else { return "…" }
    return String(singleLine.prefix(width - 1)) + "…"
}

private func wrap(_ value: String, width: Int) -> [String] {
    guard width > 1 else { return [fit(value, width: width)] }
    var lines: [String] = []
    var current = ""

    func flushCurrent() {
        guard !current.isEmpty else { return }
        lines.append(current)
        current = ""
    }

    for word in value.split(whereSeparator: \.isWhitespace).map(String.init) {
        if word.count > width {
            flushCurrent()
            var remainder = word
            while remainder.count > width {
                lines.append(String(remainder.prefix(width)))
                remainder.removeFirst(width)
            }
            current = remainder
        } else if current.isEmpty {
            current = word
        } else if current.count + 1 + word.count <= width {
            current += " \(word)"
        } else {
            flushCurrent()
            current = word
        }
    }
    flushCurrent()
    return lines.isEmpty ? [""] : lines
}
