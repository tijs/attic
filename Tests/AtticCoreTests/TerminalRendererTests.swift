@testable import AtticCLI
import Foundation
import LadderKit
import Testing

private final class RendererOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []

    func write(_ chunk: String) {
        lock.withLock { chunks.append(chunk) }
    }

    func values() -> [String] {
        lock.withLock { chunks }
    }
}

private final class RendererClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date.addTimeInterval(seconds) }
    }
}

private final class RendererTerminalSession: TerminalSessionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var begins = 0
    private(set) var ends = 0

    func begin() {
        lock.withLock { begins += 1 }
    }

    func end() {
        lock.withLock { ends += 1 }
    }

    func counts() -> (begins: Int, ends: Int) {
        lock.withLock { (begins, ends) }
    }
}

private final class RendererWidth: @unchecked Sendable {
    private let lock = NSLock()
    private var columns: Int

    init(_ columns: Int) {
        self.columns = columns
    }

    func get() -> Int {
        lock.withLock { columns }
    }

    func set(_ columns: Int) {
        lock.withLock { self.columns = columns }
    }
}

private func makeRenderer(
    output: RendererOutput,
    clock: RendererClock = RendererClock(),
    width: RendererWidth = RendererWidth(80),
    terminal: RendererTerminalSession = RendererTerminalSession(),
) -> TerminalRenderer {
    TerminalRenderer(
        output: { output.write($0) },
        now: { clock.now() },
        terminalWidth: { width.get() },
        terminalSession: terminal,
        tickInterval: nil,
    )
}

private func stripANSI(_ value: String) -> String {
    value.replacingOccurrences(
        of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",
        with: "",
        options: .regularExpression,
    )
}

struct TerminalRendererTests {
    @Test func firstFrameDoesNotMoveCursorAndNextFrameUsesActualHeight() throws {
        let output = RendererOutput()
        let renderer = makeRenderer(output: output)

        renderer.backupStarted(pending: 2, photos: 1, videos: 1)
        renderer.assetStarting(uuid: "private", filename: "IMG_0001.HEIC", size: 100)

        let chunks = output.values()
        #expect(chunks.count == 2)
        let first = try #require(chunks.first)
        #expect(first.range(of: "\u{1B}\\[[0-9]+A", options: .regularExpression) == nil)
        let firstHeight = chunks[0].filter { $0 == "\n" }.count
        #expect(firstHeight > 0)
        #expect(chunks[1].hasPrefix("\u{1B}[\(firstHeight)A"))
    }

    @Test func finalFrameClearsStaleLinesAndTracksItsOwnHeight() {
        let output = RendererOutput()
        let terminal = RendererTerminalSession()
        let renderer = makeRenderer(output: output, terminal: terminal)
        renderer.backupStarted(pending: 1, photos: 1, videos: 0)

        renderer.backupCompleted(uploaded: 1, failed: 0, totalBytes: 1024)

        let chunks = output.values()
        #expect(chunks.count == 2)
        #expect(chunks[1].contains("\u{1B}[2K"))
        #expect(chunks[1].contains("Complete"))
        #expect(chunks[1].contains("A"))
        #expect(terminal.counts().begins == 1)
        #expect(terminal.counts().ends == 1)
    }

    @Test func resizeAndLongFilenameRespectCurrentTerminalWidth() throws {
        let output = RendererOutput()
        let width = RendererWidth(80)
        let renderer = makeRenderer(output: output, width: width)
        renderer.backupStarted(pending: 1, photos: 1, videos: 0)
        width.set(24)

        renderer.assetStarting(
            uuid: "private",
            filename: "IMG_A_VERY_LONG_PRIVATE_FILENAME_THAT_MUST_NOT_WRAP.HEIC",
            size: 1,
        )

        let rendered = try stripANSI(#require(output.values().last))
        #expect(rendered.contains("…"))
        #expect(!rendered.contains("MUST_NOT_WRAP"))
        for line in rendered.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            #expect(line.count <= 24)
        }
    }

    @Test func terminalCellWidthFitsEmojiCJKCombiningMarksAndNarrowColumns() {
        #expect(terminalDisplayWidth("ASCII") == 5)
        #expect(terminalDisplayWidth("界") == 2)
        #expect(terminalDisplayWidth("🙂") >= 2)
        #expect(terminalDisplayWidth("©️") >= 2)
        #expect(terminalDisplayWidth("1️⃣") >= 2)
        #expect(terminalDisplayWidth("e\u{301}") == 1)

        for value in ["🙂🙂🙂", "界界界", "e\u{301}e\u{301}e\u{301}"] {
            #expect(terminalDisplayWidth(fit(value, width: 5)) <= 5)
        }
        #expect(fit("界", width: 1) == "…")
        for line in wrap("界界界 emoji🙂🙂 combining-e\u{301}", width: 4) {
            #expect(terminalDisplayWidth(line) <= 4)
        }
    }

    @Test func unicodeFilenameResizeKeepsEveryPhysicalRowWithinNewWidth() throws {
        let output = RendererOutput()
        let width = RendererWidth(40)
        let renderer = makeRenderer(output: output, width: width)
        renderer.backupStarted(pending: 1, photos: 1, videos: 0)
        renderer.assetStarting(uuid: "private", filename: "🙂-東京-e\u{301}-archive.HEIC", size: 1)
        width.set(14)
        renderer.assetStarting(uuid: "private", filename: "🙂🙂東京東京e\u{301}e\u{301}.HEIC", size: 1)

        let rendered = try stripANSI(#require(output.values().last))
        #expect(rendered.contains("…"))
        for line in rendered.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            #expect(terminalDisplayWidth(String(line)) <= 14)
        }
        let previousHeight = output.values()[1].filter { $0 == "\n" }.count
        #expect(try #require(output.values().last).hasPrefix("\u{1B}[\(previousHeight)A"))
    }

    @Test func concurrentCallbacksAreSerializedAsCompleteFrames() {
        let output = RendererOutput()
        let renderer = makeRenderer(output: output)
        renderer.backupStarted(pending: 50, photos: 50, videos: 0)
        let firstHeight = output.values()[0].filter { $0 == "\n" }.count

        DispatchQueue.concurrentPerform(iterations: 50) { index in
            renderer.assetStarting(uuid: "\(index)", filename: "IMG_\(index).HEIC", size: index)
        }

        let chunks = output.values()
        #expect(chunks.count == 51)
        for chunk in chunks.dropFirst() {
            #expect(chunk.hasPrefix("\u{1B}[\(firstHeight)A"))
            #expect(chunk.filter { $0 == "\n" }.count == firstHeight)
        }
    }

    @Test func pauseResumeAndClockProduceImmutableSnapshots() throws {
        let output = RendererOutput()
        let clock = RendererClock()
        let renderer = makeRenderer(output: output, clock: clock)
        renderer.backupStarted(pending: 1, photos: 1, videos: 0)
        clock.advance(5)
        renderer.backupPaused(reason: "Network unavailable")
        clock.advance(3)
        renderer.backupResumed()

        let chunks = output.values()
        #expect(stripANSI(chunks[1]).contains("Status    ⏸ Network unavailable"))
        #expect(chunks[1].contains("\u{1B}[33m"))
        #expect(stripANSI(chunks[1]).contains("00:00:00"))
        #expect(try stripANSI(#require(chunks.last)).contains("00:00:05"))
        #expect(stripANSI(chunks[0]).contains("00:00:00"))
    }

    @Test func sanitizesTerminalControlsInEveryDynamicRenderPath() {
        let output = RendererOutput()
        let renderer = makeRenderer(output: output)
        renderer.backupStarted(pending: 1, photos: 1, videos: 0)
        renderer.assetStarting(
            uuid: "private",
            filename: "safe\u{1B}[999A-file\u{7}-name.HEIC",
            size: 1,
        )
        renderer.backupPaused(reason: "offline\u{009D}terminal-title\u{009C} now")
        renderer.backupResumed()
        renderer.diagnostic(message: "diag\u{1B}Pdevice-payload\u{1B}\\end")
        renderer.assetFailed(
            uuid: "private",
            filename: "failed\u{009B}12A.HEIC",
            message: "provider\u{1B}]2;owned-title\u{7} error",
            classification: .other,
        )
        renderer.backupCompleted(uploaded: 0, failed: 1, totalBytes: 0)

        let transcript = output.values().joined()
        #expect(!transcript.contains("\u{1B}[999A"))
        #expect(!transcript.contains("\u{009B}"))
        #expect(!transcript.contains("\u{009D}"))
        #expect(!transcript.contains("\u{009C}"))
        #expect(!transcript.contains("\u{7}"))
        #expect(!transcript.contains("terminal-title"))
        #expect(!transcript.contains("device-payload"))
        #expect(!transcript.contains("owned-title"))

        let plain = stripANSI(transcript)
        #expect(plain.contains("safe-file -name.HEIC") || plain.contains("safe-file-name.HEIC"))
        #expect(plain.contains("offline now") || plain.contains("offline  now"))
        #expect(plain.contains("Warning: diagend") || plain.contains("Warning: diag end"))
        #expect(plain.contains("failed.HEIC: provider error") || plain.contains("failed.HEIC: provider  error"))
    }

    @Test func failuresAreRenderedOnlyInFinalFrame() throws {
        let output = RendererOutput()
        let renderer = makeRenderer(output: output)
        renderer.backupStarted(pending: 1, photos: 1, videos: 0)
        renderer.assetFailed(
            uuid: "private",
            filename: "IMG_FAILED.HEIC",
            message: "provider failed",
            classification: .permanentlyUnavailable,
        )
        renderer.backupCompleted(uploaded: 0, failed: 1, totalBytes: 0)

        let rawFinal = try #require(output.values().last)
        let final = stripANSI(rawFinal)
        #expect(final.contains("Completed with 1 error"))
        #expect(rawFinal.contains("\u{1B}[32m✓\u{1B}[0m"))
        #expect(final.contains("IMG_FAILED.HEIC"))
        #expect(final.contains("provider failed"))
        #expect(final.contains("~/.attic/unavailable-assets.json"))
    }

    @Test func diagnosticsRemainInsideSerializedFrames() throws {
        let output = RendererOutput()
        let renderer = makeRenderer(output: output)
        renderer.backupStarted(pending: 1, photos: 1, videos: 0)
        renderer.diagnostic(message: "Manifest save failed")
        renderer.backupCompleted(uploaded: 1, failed: 0, totalBytes: 10)

        let chunks = output.values()
        #expect(stripANSI(chunks[1]).contains("Warning: Manifest save failed"))
        #expect(try stripANSI(#require(chunks.last)).contains("Warning: Manifest save failed"))
    }

    @Test func finishBeforeLateStartDoesNotActivateTerminal() {
        let output = RendererOutput()
        let terminal = RendererTerminalSession()
        let renderer = makeRenderer(output: output, terminal: terminal)

        renderer.finish()
        renderer.backupStarted(pending: 1, photos: 1, videos: 0)

        #expect(output.values().isEmpty)
        #expect(terminal.counts().begins == 0)
        #expect(terminal.counts().ends == 0)
    }

    @Test func explicitFinishRestoresTerminalAfterCancellationExactlyOnce() {
        let output = RendererOutput()
        let terminal = RendererTerminalSession()
        let renderer = makeRenderer(output: output, terminal: terminal)
        renderer.backupStarted(pending: 1, photos: 1, videos: 0)

        renderer.finish()
        renderer.finish()
        let chunksAfterFinish = output.values().count
        renderer.assetStarting(uuid: "late", filename: "late", size: 1)

        #expect(output.values().count == chunksAfterFinish)
        #expect(terminal.counts().begins == 1)
        #expect(terminal.counts().ends == 1)
    }
}
