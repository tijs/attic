import Foundation
import Network

/// Real network monitor using `NWPathMonitor`.
///
/// Detects network availability changes in real time. Used by the backup
/// pipeline to pause uploads when the network drops and resume when it returns.
public final class NWPathNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "attic.network-monitor")
    private let lock = NSLock()
    private var currentStatus: NWPath.Status = .satisfied

    /// Stabilization period before declaring network restored.
    /// Prevents thrashing on flicker (rapid drop/restore cycles).
    private let stabilizationDelay: Duration = .seconds(3)

    public init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock {
                self.currentStatus = path.status
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    public var isNetworkAvailable: Bool {
        lock.withLock { currentStatus == .satisfied }
    }

    public func waitForNetwork(timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        let pollInterval: Duration = .milliseconds(500)

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()

            if isNetworkAvailable {
                // Wait for stabilization to avoid flicker, capped to remaining time
                let remaining = deadline - ContinuousClock.now
                let stabilize = min(stabilizationDelay, remaining)
                if stabilize > .zero {
                    try await Task.sleep(for: stabilize)
                }
                try Task.checkCancellation()

                // Confirm network is still up after stabilization
                if isNetworkAvailable {
                    return true
                }
            }

            try await Task.sleep(for: pollInterval)
        }

        return false
    }
}
