import Foundation

/// Retry an async operation with exponential backoff.
///
/// Handles transient network failures (e.g. after sleep/wake).
/// Respects Task cancellation to bail out immediately.
public func withRetry<T: Sendable>(
    maxAttempts: Int = 3,
    baseDelay: Duration = .seconds(1),
    operation: @Sendable () async throws -> T
) async throws -> T {
    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch {
            if attempt == maxAttempts { throw error }

            // Don't retry if cancelled
            try Task.checkCancellation()

            // Only retry on transient/network errors
            guard isTransient(error) else { throw error }

            let delay = baseDelay * Int(pow(2.0, Double(attempt - 1)))
            try await Task.sleep(for: delay)
        }
    }
    fatalError("unreachable")
}

/// Determine whether an error is transient and worth retrying.
private func isTransient(_ error: Error) -> Bool {
    let message = String(describing: error).lowercased()
    let transientPatterns = [
        "timeout", "econnreset", "econnrefused", "epipe",
        "socket", "network", "fetch failed",
    ]
    return transientPatterns.contains { message.contains($0) }
}
