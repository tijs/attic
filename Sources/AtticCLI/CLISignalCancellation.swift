import Darwin
import Foundation

/// Bridges process signals into cooperative Swift task cancellation for the
/// duration of a CLI operation. Signal dispositions are restored after the
/// last registered operation, so tests and embedding processes do not inherit
/// process-global changes.
enum CLISignalCancellation {
    static func run<Value: Sendable>(
        onHandlersInstalled: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> Value,
    ) async throws -> Value {
        let relay = TaskCancellationRelay()
        let registration = SignalCancellationRegistry.shared.register {
            relay.cancel()
        }
        defer { registration.cancel() }

        // Install the process-global handlers before the child task can begin.
        // If a signal lands between registration and attachment, the relay
        // remembers it and immediately cancels the task once it exists.
        onHandlersInstalled()
        let task = Task { try await operation() }
        relay.attach {
            task.cancel()
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private final class TaskCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var cancelTask: (@Sendable () -> Void)?

    func attach(cancelTask: @escaping @Sendable () -> Void) {
        let shouldCancel = lock.withLock {
            if cancellationRequested {
                return true
            }
            self.cancelTask = cancelTask
            return false
        }
        if shouldCancel {
            cancelTask()
        }
    }

    func cancel() {
        let action = lock.withLock {
            cancellationRequested = true
            defer { cancelTask = nil }
            return cancelTask
        }
        action?()
    }
}

private final class SignalCancellationRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let action = lock.withLock {
            defer { cancellation = nil }
            return cancellation
        }
        action?()
    }

    deinit {
        cancel()
    }
}

private final class SignalCancellationRegistry: @unchecked Sendable {
    static let shared = SignalCancellationRegistry()

    private struct PreviousHandler {
        let value: (@convention(c) (Int32) -> Void)?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.tijs.attic.signal-cancellation")
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    private var sources: [Int32: DispatchSourceSignal] = [:]
    private var previousHandlers: [Int32: PreviousHandler] = [:]

    func register(cancellation: @escaping @Sendable () -> Void) -> SignalCancellationRegistration {
        let id = UUID()
        lock.withLock {
            if callbacks.isEmpty {
                installSignalSourcesLocked()
            }
            callbacks[id] = cancellation
        }
        return SignalCancellationRegistration { [weak self] in
            self?.unregister(id: id)
        }
    }

    private func unregister(id: UUID) {
        lock.withLock {
            callbacks.removeValue(forKey: id)
            if callbacks.isEmpty {
                restoreSignalHandlersLocked()
            }
        }
    }

    private func installSignalSourcesLocked() {
        for signalNumber in [SIGINT, SIGTERM] {
            previousHandlers[signalNumber] = PreviousHandler(value: signal(signalNumber, SIG_IGN))
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                self?.cancelRegisteredOperations()
            }
            sources[signalNumber] = source
            source.activate()
        }
    }

    private func restoreSignalHandlersLocked() {
        for (signalNumber, source) in sources {
            source.cancel()
            if let previous = previousHandlers[signalNumber] {
                if let handler = previous.value {
                    signal(signalNumber, handler)
                } else {
                    signal(signalNumber, SIG_DFL)
                }
            }
        }
        sources.removeAll()
        previousHandlers.removeAll()
    }

    private func cancelRegisteredOperations() {
        let actions = lock.withLock { Array(callbacks.values) }
        for action in actions {
            action()
        }
    }
}
