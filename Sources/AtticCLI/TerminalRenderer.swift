import AtticCore
import Foundation
import LadderKit

/// ANSI live-updating dashboard for backup progress.
///
/// Redraws a fixed-height block in-place using ANSI escape codes.
/// Shows progress bar, counts, speed, current file, and elapsed time.
final class TerminalRenderer: BackupProgressDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var state = RenderState()
    private var startTime: Date?
    private var lastRenderTime: Date?
    private let spinner: PreparationSpinner?
    private var originalTermios: termios?
    private var tickTask: Task<Void, Never>?

    init(spinner: PreparationSpinner? = nil) {
        self.spinner = spinner
    }

    /// Disable stdin echo and canonical mode so keypresses don't disrupt the dashboard.
    private func disableInputEcho() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw
        raw.c_lflag &= ~UInt(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }

    /// Restore the original terminal settings.
    private func restoreInputEcho() {
        guard var original = originalTermios else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        originalTermios = nil
    }

    private struct RenderState {
        var total: Int = 0
        var photos: Int = 0
        var videos: Int = 0
        var uploaded: Int = 0
        var failed: Int = 0
        var totalBytes: Int = 0
        var currentFile: String = ""
        var currentBatch: Int = 0
        var totalBatches: Int = 0
        var uploadedPhotos: Int = 0
        var uploadedVideos: Int = 0
        var headerPrinted: Bool = false
        var isPaused: Bool = false
        var pauseReason: String = ""
        var pauseStarted: Date?
        var totalPauseDuration: TimeInterval = 0
        var failedAssets: [(filename: String, message: String)] = []
    }

    // MARK: - BackupProgressDelegate

    func backupStarted(pending: Int, photos: Int, videos: Int) {
        spinner?.stop()
        disableInputEcho()
        lock.withLock {
            state.total = pending
            state.photos = photos
            state.videos = videos
            startTime = Date()
        }
        render()
        startTick()
    }

    /// Refresh the display every second so elapsed time and speed stay current.
    private func startTick() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.render()
            }
        }
    }

    func batchStarted(batchNumber: Int, totalBatches: Int, assetCount: Int) {
        lock.withLock {
            state.currentBatch = batchNumber
            state.totalBatches = totalBatches
        }
        render()
    }

    func assetStarting(uuid: String, filename: String, size: Int) {
        lock.withLock {
            state.currentFile = "\(filename) (\(formatBytes(size)))"
        }
        render()
    }

    func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int) {
        lock.withLock {
            state.uploaded += 1
            state.totalBytes += size
            state.currentFile = "\(filename) (\(formatBytes(size)))"
            if type == .photo { state.uploadedPhotos += 1 } else { state.uploadedVideos += 1 }
        }
        render()
    }

    func assetRetrying(uuid: String, filename: String, attempt: Int, maxAttempts: Int) {
        lock.withLock {
            state.currentFile = "\u{1b}[33m\(filename) — retry \(attempt)/\(maxAttempts)\u{1b}[0m"
        }
        render()
    }

    func assetFailed(uuid: String, filename: String, message: String) {
        lock.withLock {
            state.failed += 1
            state.currentFile = "\(filename) — \(message)"
            if state.failedAssets.count < 50 {
                state.failedAssets.append((filename: filename, message: message))
            }
        }
        render()
    }

    func manifestSaved(entriesCount: Int) {
        // No visual update needed
    }

    func backupPaused(reason: String) {
        lock.withLock {
            state.isPaused = true
            state.pauseReason = reason
            state.pauseStarted = Date()
        }
        render()
    }

    func backupResumed() {
        lock.withLock {
            state.isPaused = false
            if let pauseStart = state.pauseStarted {
                state.totalPauseDuration += Date().timeIntervalSince(pauseStart)
            }
            state.pauseStarted = nil
            state.pauseReason = ""
        }
        render()
    }

    func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int) {
        tickTask?.cancel()
        tickTask = nil
        lock.withLock {
            state.uploaded = uploaded
            state.failed = failed
            state.totalBytes = totalBytes
            state.currentFile = ""
        }
        renderFinal()
    }

    // MARK: - Rendering

    private func render() {
        let (s, elapsed): (RenderState, TimeInterval) = lock.withLock {
            let total = startTime.map { Date().timeIntervalSince($0) } ?? 0
            // Exclude pause time from elapsed for accurate speed calculation
            var currentPause: TimeInterval = 0
            if let pauseStart = state.pauseStarted {
                currentPause = Date().timeIntervalSince(pauseStart)
            }
            let active = total - state.totalPauseDuration - currentPause
            return (state, max(0, active))
        }
        let speed = elapsed > 0 ? Double(s.totalBytes) / elapsed : 0

        let completed = s.uploaded + s.failed
        let barWidth = 30
        let filled = s.total > 0 ? (completed * barWidth) / s.total : 0
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)

        var lines: [String] = []

        if !s.headerPrinted {
            lines.append("")
            lock.withLock { state.headerPrinted = true }
        }

        lines.append("  Progress  [\(bar)] \(completed)/\(s.total)")
        lines.append("  Photos    \(s.uploadedPhotos) uploaded")
        lines.append("  Videos    \(s.uploadedVideos) uploaded")
        lines.append("  Speed     \(s.isPaused ? "—" : "\(formatBytes(Int(speed)))/s")")
        lines.append("  Errors    \(s.failed)")
        lines.append("")
        if s.isPaused, let pauseStart = s.pauseStarted {
            let waitTime = Date().timeIntervalSince(pauseStart)
            lines.append("  Status    \u{1b}[33m⏸ \(s.pauseReason) (\(formatDuration(waitTime)))\u{1b}[0m")
        } else {
            lines.append("  Current   \(s.currentFile)")
        }
        lines.append("  Elapsed   \(formatDuration(elapsed))")

        // Move cursor up to overwrite previous render (8 lines of content)
        let now = Date()
        let shouldMoveCursor: Bool = lock.withLock {
            if lastRenderTime != nil {
                return true
            }
            lastRenderTime = now
            return false
        }

        if shouldMoveCursor {
            // Move up 8 lines and clear each
            print("\u{1b}[\(lines.count)A", terminator: "")
        }
        lock.withLock { lastRenderTime = now }

        for line in lines {
            print("\u{1b}[2K\(line)")
        }

        fflush(stdout)
    }

    private func renderFinal() {
        restoreInputEcho()

        let s: RenderState = lock.withLock { state }
        let elapsed = lock.withLock { startTime.map { Date().timeIntervalSince($0) } ?? 0 }
        let speed = elapsed > 0 ? Double(s.totalBytes) / elapsed : 0

        // Overwrite the live display in-place
        let lineCount = 8
        print("\u{1b}[\(lineCount)A", terminator: "")

        let status = s.failed > 0 ? "Completed with \(s.failed) error\(s.failed == 1 ? "" : "s")" : "Complete"
        print("\u{1b}[2K  \u{1b}[32m✓\u{1b}[0m \(status) — \(formatBytes(s.totalBytes)) in \(formatDuration(elapsed))")
        print("\u{1b}[2K  Photos    \(s.uploadedPhotos) uploaded")
        print("\u{1b}[2K  Videos    \(s.uploadedVideos) uploaded")
        print("\u{1b}[2K  Speed     \(formatBytes(Int(speed)))/s avg")
        print("\u{1b}[2K  Errors    \(s.failed)")

        // Use remaining lines for failures or clear them
        if s.failed > 0 {
            print("\u{1b}[2K")
            print("\u{1b}[2K  Failed assets:")
            // Clear the last live-display line (Elapsed) before printing failure details
            print("\u{1b}[2K", terminator: "")
            for failure in s.failedAssets {
                print("  ✗ \(failure.filename): \(failure.message)")
            }
            if s.failed > s.failedAssets.count {
                print("  ... and \(s.failed - s.failedAssets.count) more")
            }
            print("")
            print("Tip: Run `attic backup` again to retry failed assets.")
        } else {
            // Clear the remaining 3 lines (blank, Current, Elapsed)
            for _ in 0 ..< 3 {
                print("\u{1b}[2K")
            }
        }

        fflush(stdout)
    }
}

// MARK: - Formatting

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return String(format: "%02d:%02d:%02d", h, m, s)
}
