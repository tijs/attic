import Foundation

/// Prevents idle system sleep and App Nap during long-running operations.
///
/// Uses `ProcessInfo.beginActivity()` with `.userInitiated` and
/// `.idleSystemSleepDisabled` options. RAII-style: the assertion is
/// automatically released when this object is deallocated.
///
/// This prevents idle sleep (screen off timer, desktop inactivity) but
/// cannot prevent user-initiated sleep (lid close, Apple menu > Sleep).
public final class PowerAssertion: @unchecked Sendable {
    private let activity: NSObjectProtocol

    public init(reason: String) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
    }

    public func end() {
        ProcessInfo.processInfo.endActivity(activity)
    }

    deinit {
        end()
    }
}
