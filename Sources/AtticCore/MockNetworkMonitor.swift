import Foundation

/// In-memory network monitor mock for tests.
///
/// Controllable `isAvailable` property. `waitForNetwork` polls with a short
/// interval and respects both timeout and cancellation.
public actor MockNetworkMonitor: NetworkMonitoring {
    private var available: Bool

    public init(available: Bool = true) {
        self.available = available
    }

    public var isNetworkAvailable: Bool {
        available
    }

    /// Simulate network recovery.
    public func setAvailable() {
        available = true
    }

    /// Simulate network loss.
    public func setUnavailable() {
        available = false
    }

    public func waitForNetwork(timeout: Duration) async throws -> Bool {
        if available { return true }

        let deadline = ContinuousClock.now + timeout
        let pollInterval: Duration = .milliseconds(50)

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
            if available { return true }
        }

        return false
    }
}
