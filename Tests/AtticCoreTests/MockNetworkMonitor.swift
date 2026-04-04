@testable import AtticCore
import Foundation

/// In-memory network monitor mock for tests.
///
/// Controllable `isAvailable` property. `waitForNetwork` polls with a short
/// interval and respects both timeout and cancellation.
actor MockNetworkMonitor: NetworkMonitoring {
    private var available: Bool

    init(available: Bool = true) {
        self.available = available
    }

    var isNetworkAvailable: Bool {
        available
    }

    /// Simulate network recovery.
    func setAvailable() {
        available = true
    }

    /// Simulate network loss.
    func setUnavailable() {
        available = false
    }

    func waitForNetwork(timeout: Duration) async throws -> Bool {
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
