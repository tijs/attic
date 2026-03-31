import Foundation
import AtticCore
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

    init(spinner: PreparationSpinner? = nil) {
        self.spinner = spinner
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
    }

    // MARK: - BackupProgressDelegate

    func backupStarted(pending: Int, photos: Int, videos: Int) {
        spinner?.stop()
        lock.withLock {
            state.total = pending
            state.photos = photos
            state.videos = videos
            startTime = Date()
        }
        render()
    }

    func batchStarted(batchNumber: Int, totalBatches: Int, assetCount: Int) {
        lock.withLock {
            state.currentBatch = batchNumber
            state.totalBatches = totalBatches
        }
        render()
    }

    func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int) {
        lock.withLock {
            state.uploaded += 1
            state.totalBytes += size
            state.currentFile = "\(filename) (\(formatBytes(size)))"
            if type == .photo { state.uploadedPhotos += 1 }
            else { state.uploadedVideos += 1 }
        }
        render()
    }

    func assetFailed(uuid: String, filename: String, message: String) {
        lock.withLock {
            state.failed += 1
            state.currentFile = "\(filename) — \(message)"
        }
        render()
    }

    func manifestSaved(entriesCount: Int) {
        // No visual update needed
    }

    func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int) {
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
            let e = startTime.map { Date().timeIntervalSince($0) } ?? 0
            return (state, e)
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
        lines.append("  Speed     \(formatBytes(Int(speed)))/s")
        lines.append("  Errors    \(s.failed)")
        lines.append("")
        lines.append("  Current   \(s.currentFile)")
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
        let s: RenderState = lock.withLock { state }
        let elapsed = lock.withLock { startTime.map { Date().timeIntervalSince($0) } ?? 0 }

        // Clear the live display
        let lineCount = 8
        print("\u{1b}[\(lineCount)A", terminator: "")
        for _ in 0..<lineCount {
            print("\u{1b}[2K")
        }
        print("\u{1b}[\(lineCount)A", terminator: "")

        print("Backup complete in \(formatDuration(elapsed))")
        print("  Uploaded: \(s.uploaded) (\(formatBytes(s.totalBytes)))")
        if s.failed > 0 {
            print("  Failed:   \(s.failed)")
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
