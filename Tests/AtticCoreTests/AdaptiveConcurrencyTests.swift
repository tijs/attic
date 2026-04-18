import Foundation
import LadderKit
import Testing

@testable import AtticCore

@Suite("AIMDController")
struct AIMDControllerTests {
    @Test("Starts at initial limit within bounds")
    func initialLimit() async {
        let c = AIMDController(config: .init(initialLimit: 6, minLimit: 1, maxLimit: 12))
        #expect(await c.currentLimit() == 6)
    }

    @Test("Clamps initial limit to min/max")
    func clampsInitial() async {
        let lo = AIMDController(config: .init(initialLimit: 0, minLimit: 1, maxLimit: 12))
        #expect(await lo.currentLimit() == 1)
        let hi = AIMDController(config: .init(initialLimit: 20, minLimit: 1, maxLimit: 12))
        #expect(await hi.currentLimit() == 12)
    }

    @Test("High transient failure rate halves the limit")
    func backoffOnFailures() async {
        let c = AIMDController(config: .init(initialLimit: 8, minLimit: 1, maxLimit: 12))
        // 10 failures then 10 successes: once the window fills (20 items),
        // the rate is 0.5 → backoff.
        for _ in 0 ..< 10 { await c.record(.transientFailure) }
        for _ in 0 ..< 10 { await c.record(.success) }
        #expect(await c.currentLimit() == 4)
    }

    @Test("Permanent failures are ignored")
    func permanentIgnored() async {
        let c = AIMDController(config: .init(initialLimit: 8, minLimit: 1, maxLimit: 12))
        for _ in 0 ..< 40 { await c.record(.permanentFailure) }
        #expect(await c.currentLimit() == 8)
    }

    @Test("Clean sliding window grows limit additively")
    func recover() async {
        let c = AIMDController(config: .init(initialLimit: 4, minLimit: 1, maxLimit: 12))
        // 20 successes fills the window with rate 0 → +1.
        for _ in 0 ..< 20 { await c.record(.success) }
        #expect(await c.currentLimit() == 5)
    }

    @Test("Sliding window catches a burst that straddles tumbling boundaries")
    func slidingCatchesStraddlingBurst() async {
        // With a *tumbling* window this would miss: 6 failures late in window
        // N + 6 early in window N+1 yield rates of 0.30 in each, under the
        // threshold. Sliding eval on every outcome catches the true 60% rate.
        let c = AIMDController(config: .init(initialLimit: 8, minLimit: 1, maxLimit: 12))
        // First fill the window with 14 successes + 6 failures (rate 0.30 —
        // not > threshold, no change).
        for _ in 0 ..< 14 { await c.record(.success) }
        for _ in 0 ..< 6 { await c.record(.transientFailure) }
        #expect(await c.currentLimit() == 8)
        // Now slide in 6 more failures; oldest successes drop, rate climbs
        // above 0.30 and triggers backoff.
        for _ in 0 ..< 6 { await c.record(.transientFailure) }
        #expect(await c.currentLimit() == 4)
    }

    @Test("Window clears on limit change to avoid immediate re-trigger")
    func windowClearsOnChange() async {
        let c = AIMDController(config: .init(initialLimit: 8, minLimit: 1, maxLimit: 12))
        // Force backoff.
        for _ in 0 ..< 10 { await c.record(.transientFailure) }
        for _ in 0 ..< 10 { await c.record(.success) }
        #expect(await c.currentLimit() == 4)
        // Immediately feeding another failure must not re-backoff — the window
        // is empty post-change. It takes another full window to re-trigger.
        await c.record(.transientFailure)
        #expect(await c.currentLimit() == 4)
    }

    @Test("Respects minLimit floor")
    func minLimitFloor() async {
        let c = AIMDController(config: .init(initialLimit: 2, minLimit: 2, maxLimit: 12))
        for _ in 0 ..< 40 { await c.record(.transientFailure) }
        #expect(await c.currentLimit() == 2)
    }

    @Test("Respects maxLimit ceiling")
    func maxLimitCeiling() async {
        let c = AIMDController(config: .init(initialLimit: 3, minLimit: 1, maxLimit: 3))
        for _ in 0 ..< 40 { await c.record(.success) }
        #expect(await c.currentLimit() == 3)
    }
}
