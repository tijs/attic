import Foundation

/// Retry an async operation with exponential backoff and jitter.
///
/// Handles transient server errors (5xx, throttling, timeouts).
/// Network-down errors (no connectivity) are NOT retried — they fail fast
/// so the pipeline-level network pause can activate sooner.
/// Respects Task cancellation to bail out immediately.
public func withRetry<T: Sendable>(
    maxAttempts: Int = 3,
    baseDelay: Duration = .seconds(1),
    maxDelay: Duration = .seconds(30),
    operation: @Sendable () async throws -> T,
) async throws -> T {
    for attempt in 1 ... maxAttempts {
        do {
            return try await operation()
        } catch {
            if attempt == maxAttempts { throw error }

            // Don't retry if cancelled
            try Task.checkCancellation()

            // Network-down errors fail fast (no retry)
            if isNetworkDown(error) { throw error }

            // Only retry on transient server errors
            guard isTransient(error) else { throw error }

            // Exponential backoff with jitter
            let exponential = baseDelay * Int(pow(2.0, Double(attempt - 1)))
            let capped = min(exponential, maxDelay)
            let cappedMs = Int(capped.components.seconds) * 1000
                + Int(capped.components.attoseconds / 1_000_000_000_000_000)
            let jittered: Duration = .milliseconds(Int.random(in: 0 ... max(1, cappedMs)))
            try await Task.sleep(for: jittered)
        }
    }
    fatalError("unreachable")
}

// MARK: - Error classification

/// Network-down errors: no connectivity, fail fast (don't waste retry attempts).
public func isNetworkDown(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .dataNotAllowed,
             .internationalRoamingOff:
            return true
        default:
            return false
        }
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        return [-1009, -1005, -1004, -1003, -1020, -1018].contains(nsError.code)
    }
    return false
}

/// Server-transient errors: worth retrying with backoff.
private func isTransient(_ error: Error) -> Bool {
    // URLSession timeout (server-side)
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    // S3 HTTP-level transient errors
    if let s3Error = error as? S3ClientError {
        switch s3Error {
        case let .httpError(status, _):
            return [408, 429, 500, 502, 503, 504].contains(status)
        case let .s3Error(code, _):
            return [
                "SlowDown",
                "ServiceUnavailable",
                "InternalError",
                "RequestTimeout",
            ].contains(code)
        case .unexpectedResponse:
            return false
        }
    }

    // NSError fallback for bridged errors
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        return [-1001].contains(nsError.code) // timedOut
    }

    return false
}
