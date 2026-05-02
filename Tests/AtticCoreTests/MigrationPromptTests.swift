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
