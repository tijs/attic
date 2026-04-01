@testable import AtticCore
import Foundation
import Testing

struct RetryPolicyTests {
    @Test func returnsResultOnFirstSuccess() async throws {
        let result = try await withRetry { 42 }
        #expect(result == 42)
    }

    @Test func retriesOnTransientErrorThenSucceeds() async throws {
        let counter = Counter()
        let result: String = try await withRetry(baseDelay: .milliseconds(10)) {
            let attempt = await counter.increment()
            if attempt == 1 { throw TransientError("fetch failed") }
            return "ok"
        }
        #expect(result == "ok")
        #expect(await counter.value == 2)
    }

    @Test func doesNotRetryOnNonTransientError() async {
        let counter = Counter()
        do {
            let _: Int = try await withRetry(baseDelay: .milliseconds(10)) {
                await counter.increment()
                throw NonTransientError("Access denied")
            }
        } catch {
            #expect(error is NonTransientError)
        }
        #expect(await counter.value == 1)
    }

    @Test func throwsAfterMaxAttempts() async {
        let counter = Counter()
        do {
            let _: Int = try await withRetry(
                maxAttempts: 3,
                baseDelay: .milliseconds(10),
            ) {
                await counter.increment()
                throw TransientError("ECONNRESET")
            }
        } catch {
            #expect(error is TransientError)
        }
        #expect(await counter.value == 3)
    }

    @Test func respectsCancellation() async {
        let counter = Counter()
        let task = Task {
            try await withRetry(
                maxAttempts: 5,
                baseDelay: .milliseconds(100),
            ) {
                await counter.increment()
                throw TransientError("timeout")
            } as Int
        }

        // Give it time to fail once and enter backoff
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            #expect(error is CancellationError)
        }
        // Should have been cancelled before exhausting all 5 attempts
        #expect(await counter.value < 5)
    }
}

// MARK: - Test helpers

private struct TransientError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

private struct NonTransientError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

private actor Counter {
    var value = 0
    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
