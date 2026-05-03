@testable import AtticCore
import Foundation
import Testing

@Suite("MigrationPrompt.decide")
struct MigrationPromptDecideTests {
    @Test func nonTtyAlwaysReturnsNonInteractive() {
        let decision = MigrationPrompt.decide(isTTY: false, answer: { "y" })
        #expect(decision == .nonInteractive)
    }

    @Test func ttyEmptyInputAbortsForSafety() {
        // Default-N: an empty answer (piped /dev/null, agent harness) must
        // not start a one-shot migration silently.
        let decision = MigrationPrompt.decide(isTTY: true, answer: { "" })
        #expect(decision == .abort)
    }

    @Test func ttyNilAnswerAborts() {
        let decision = MigrationPrompt.decide(isTTY: true, answer: { nil })
        #expect(decision == .abort)
    }

    @Test func ttyYesProceeds() {
        #expect(MigrationPrompt.decide(isTTY: true, answer: { "y" }) == .proceed)
        #expect(MigrationPrompt.decide(isTTY: true, answer: { "Y" }) == .proceed)
        #expect(MigrationPrompt.decide(isTTY: true, answer: { "yes" }) == .proceed)
        #expect(MigrationPrompt.decide(isTTY: true, answer: { "  YES  " }) == .proceed)
    }

    @Test func ttyNoAborts() {
        #expect(MigrationPrompt.decide(isTTY: true, answer: { "n" }) == .abort)
        #expect(MigrationPrompt.decide(isTTY: true, answer: { "no" }) == .abort)
    }

    @Test func ttyAnyOtherInputAborts() {
        #expect(MigrationPrompt.decide(isTTY: true, answer: { "maybe" }) == .abort)
        #expect(MigrationPrompt.decide(isTTY: true, answer: { "1" }) == .abort)
    }

    @Test func messageIncludesEntryCount() {
        let body = MigrationPrompt.message(count: 24179)
        #expect(body.contains("24179"))
        #expect(body.contains("v1 manifest"))
    }

    @Test func nonInteractiveHintMentionsMigrateCommand() {
        #expect(MigrationPrompt.nonInteractiveHint.contains("attic migrate"))
    }
}

@Suite("MigrationPrompt.runtimeEstimate")
struct MigrationPromptRuntimeEstimateTests {
    @Test func zeroIsUnderAMinute() {
        #expect(MigrationPrompt.runtimeEstimate(entryCount: 0) == "under a minute")
    }

    @Test func subMinuteWindowReportsUnderAMinute() {
        // entryCount = 1: slowSeconds = 1/15 ≈ 0.067 → under a minute.
        #expect(MigrationPrompt.runtimeEstimate(entryCount: 1) == "under a minute")
        // entryCount = 600: slowSeconds = 40 → still under a minute (the
        // sub-minute branch must not collapse to "up to ~1 minute").
        #expect(MigrationPrompt.runtimeEstimate(entryCount: 600) == "under a minute")
        // entryCount = 899: slowSeconds = 59.93 → under a minute.
        #expect(MigrationPrompt.runtimeEstimate(entryCount: 899) == "under a minute")
    }

    @Test func crossesMinuteBoundary() {
        // entryCount = 900: slowSeconds = 60 exactly → first non-zero slow.
        let firstMinute = MigrationPrompt.runtimeEstimate(entryCount: 900)
        #expect(firstMinute.hasPrefix("up to ~"), "got: \(firstMinute)")
        #expect(firstMinute.contains("minute"))
    }

    @Test func singularPluralization() {
        // Find an entryCount where slowMinutes rounds to 1 and fastMinutes is 0.
        // entryCount = 900: slow = 60s → 1 min, fast = 20s → 0 min ⇒ "up to ~1 minute".
        #expect(MigrationPrompt.runtimeEstimate(entryCount: 900) == "up to ~1 minute")
        // entryCount = 1500: slow = 100s → 2 min, fast = 33s → 1 min ⇒ "roughly 1–2 minutes".
        // entryCount such that slowMinutes = 2 and fastMinutes = 0:
        // need slow ≈ 90–149s (rounds to 2) and fast < 30s. fast/slow ratio is 1/3,
        // so fast ∈ [30, 49.6]s — fast rounds to 1 there. Plural-when-slow=1 only
        // happens at the borderline; tested above with the slowMinutes=1 case.
        #expect(MigrationPrompt.runtimeEstimate(entryCount: 1500).contains("minutes"))
    }

    @Test func largeLibraryProducesRange() {
        // 27_000 entries: fast = 600s = 10min, slow = 1800s = 30min.
        let estimate = MigrationPrompt.runtimeEstimate(entryCount: 27_000)
        #expect(estimate == "roughly 10–30 minutes")
    }

    @Test func neverReturnsEmptyString() {
        for n in [0, 1, 100, 1_000, 27_000, 100_000, 1_000_000] {
            let estimate = MigrationPrompt.runtimeEstimate(entryCount: n)
            #expect(!estimate.isEmpty, "empty estimate at n=\(n)")
        }
    }
}
