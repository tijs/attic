import Foundation

/// Protocol for monitoring network availability.
///
/// Used by the backup pipeline to detect network loss and wait for recovery
/// (e.g., after sleep/wake). Implementations must be `Sendable` for use
/// with Swift Concurrency.
public protocol NetworkMonitoring: Sendable {
    /// Whether the network is currently available for uploads.
    var isNetworkAvailable: Bool { get async }

    /// Suspends until the network becomes available or the timeout expires.
    ///
    /// Includes a brief stabilization period (e.g., 3 seconds) before
    /// declaring network restored, to avoid thrashing on flicker.
    ///
    /// - Parameter timeout: Maximum time to wait for network recovery.
    /// - Returns: `true` if network recovered, `false` if timed out.
    /// - Throws: `CancellationError` if the task is cancelled during the wait.
    func waitForNetwork(timeout: Duration) async throws -> Bool
}
