import Foundation
import LadderKit

/// AIMD (additive-increase, multiplicative-decrease) concurrency controller.
///
/// Observation-only — implements ``AdaptiveConcurrencyControlling`` from
/// LadderKit. The exporter polls ``currentLimit()`` between dispatches and
/// reports each ``ExportOutcome`` via ``record(_:)``; this actor maintains a
/// sliding window of the last N non-permanent outcomes and adjusts the limit
/// when the transient-failure rate crosses a threshold.
///
/// - On every outcome after the window fills, the rate is re-evaluated.
/// - `rate > 0.30` → limit halves (clamped to `minLimit`); window clears.
/// - `rate <= 0.05` → limit grows by 1 (clamped to `maxLimit`); window clears.
/// - Permanent failures (shared-album unavailable) are ignored — not a signal
///   about iCloud lane health.
///
/// Clearing the window on every limit change prevents stale pre-change
/// outcomes from immediately re-tripping the new limit.
public actor AIMDController: AdaptiveConcurrencyControlling {
    public struct Config: Sendable {
        public var initialLimit: Int
        public var minLimit: Int
        public var maxLimit: Int

        public init(initialLimit: Int = 6, minLimit: Int = 1, maxLimit: Int = 12) {
            self.initialLimit = initialLimit
            self.minLimit = minLimit
            self.maxLimit = maxLimit
        }
    }

    private static let windowSize = 20
    private static let backoffThreshold = 0.30
    private static let recoverThreshold = 0.05
    private static let decreaseFactor = 0.5

    public let config: Config
    private var limit: Int
    private var window: [Bool] = []

    public init(config: Config = Config()) {
        self.config = config
        self.limit = max(config.minLimit, min(config.maxLimit, config.initialLimit))
    }

    public func currentLimit() -> Int { limit }

    public func record(_ outcome: ExportOutcome) {
        switch outcome {
        case .permanentFailure:
            return
        case .success:
            observe(transientFailure: false)
        case .transientFailure:
            observe(transientFailure: true)
        }
    }

    private func observe(transientFailure: Bool) {
        window.append(transientFailure)
        if window.count > Self.windowSize {
            window.removeFirst()
        }
        guard window.count >= Self.windowSize else { return }

        let failures = window.lazy.filter { $0 }.count
        let rate = Double(failures) / Double(window.count)

        if rate > Self.backoffThreshold {
            let target = max(config.minLimit, Int((Double(limit) * Self.decreaseFactor).rounded(.down)))
            if target != limit {
                limit = target
                window.removeAll(keepingCapacity: true)
            }
        } else if rate <= Self.recoverThreshold, limit < config.maxLimit {
            limit += 1
            window.removeAll(keepingCapacity: true)
        }
    }
}
