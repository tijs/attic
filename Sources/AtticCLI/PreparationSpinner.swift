import Foundation

/// Animated spinner shown during the preparation phase before backup uploads begin.
///
/// Displays a single line with a Braille-pattern spinner and a status message.
final class PreparationSpinner: @unchecked Sendable {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private let lock = NSLock()
    private var statusMessage = "Preparing..."
    private var animationTask: Task<Void, Never>?
    private var hasPrinted = false

    func updateStatus(_ message: String) {
        lock.withLock {
            statusMessage = message
        }
    }

    func start() {
        lock.withLock {
            hasPrinted = false
        }
        animationTask = Task {
            var frameIndex = 0

            while !Task.isCancelled {
                let message: String = self.lock.withLock {
                    self.statusMessage
                }

                let frame = Self.frames[frameIndex % Self.frames.count]
                frameIndex += 1

                let shouldMoveCursor: Bool = self.lock.withLock {
                    if self.hasPrinted {
                        return true
                    }
                    self.hasPrinted = true
                    return false
                }

                if shouldMoveCursor {
                    print("\u{1b}[1A", terminator: "")
                }
                print("\u{1b}[2K  \(frame) \(message)")
                fflush(stdout)

                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stop() {
        let printed: Bool = lock.withLock {
            animationTask?.cancel()
            animationTask = nil
            return hasPrinted
        }
        if printed {
            // Brief sleep to let the cancelled task finish its current iteration
            Thread.sleep(forTimeInterval: 0.15)
            print("\u{1b}[1A\u{1b}[2K", terminator: "")
            fflush(stdout)
        }
    }
}
