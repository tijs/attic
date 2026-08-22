import Foundation

/// Runs a user-supplied shell command after a backup finishes, so unattended
/// runs (launchd) can signal success or failure to external monitoring —
/// a healthchecks.io ping, a notification script, etc.
public enum PostRunHook {
    /// Environment passed to hook commands describing the run outcome.
    public static func environment(result: String, report: BackupReport?) -> [String: String] {
        var env = ["ATTIC_RESULT": result]
        if let report {
            env["ATTIC_UPLOADED"] = String(report.uploaded)
            env["ATTIC_FAILED"] = String(report.failed)
            env["ATTIC_SKIPPED"] = String(report.skipped)
            env["ATTIC_TOTAL_BYTES"] = String(report.totalBytes)
        }
        return env
    }

    /// How long a hook may run before it is terminated. Bounded so a hung
    /// notifier (e.g. a stalled curl) cannot keep attic alive forever —
    /// launchd must always receive the backup's own exit status.
    public static let defaultTimeout: TimeInterval = 60

    /// Run `command` via `sh -c` with `environment` merged over the current
    /// process environment. Returns the hook's exit status, or nil if the
    /// hook could not be launched or exceeded `timeout` and was terminated.
    /// Hook outcomes never affect attic's own exit code — a broken or hung
    /// notifier should not mask a successful backup.
    @discardableResult
    public static func run(
        command: String,
        environment: [String: String],
        shellPath: String = "/bin/sh",
        timeout: TimeInterval = defaultTimeout,
    ) -> Int32? {
        let mergedEnvironment = ProcessInfo.processInfo.environment
            .merging(environment) { _, new in new }

        let processID: pid_t
        switch spawnShell(command: command, environment: mergedEnvironment, shellPath: shellPath) {
        case let .success(pid):
            processID = pid
        case let .failure(errorCode):
            FileHandle.standardError.write(Data(
                "Warning: post-run hook failed to launch: \(String(cString: strerror(errorCode)))\n".utf8,
            ))
            return nil
        }

        let waiter = ChildProcessWaiter(processID: processID)
        if waiter.exited.wait(timeout: .now() + timeout) == .timedOut {
            // A negative PID targets every process in the hook's process group.
            kill(-processID, SIGTERM)
            let processExited = waiter.exited.wait(timeout: .now() + 5) == .success
            if !processExited || processGroupExists(processID) {
                kill(-processID, SIGKILL)
                if !processExited {
                    _ = waiter.exited.wait(timeout: .now() + 1)
                }
                _ = waitForProcessGroupExit(processGroupID: processID, timeout: 1)
            }
            FileHandle.standardError.write(Data(
                "Warning: post-run hook timed out after \(String(format: "%g", timeout))s and was terminated\n".utf8,
            ))
            return nil
        }

        guard let rawStatus = waiter.rawStatus else {
            FileHandle.standardError.write(Data(
                "Warning: post-run hook status could not be read\n".utf8,
            ))
            return nil
        }
        let status = terminationStatus(from: rawStatus)
        if status != 0 {
            FileHandle.standardError.write(Data(
                "Warning: post-run hook exited with status \(status)\n".utf8,
            ))
        }
        return status
    }

    private enum SpawnResult {
        case success(pid_t)
        case failure(Int32)
    }

    private static func spawnShell(
        command: String,
        environment: [String: String],
        shellPath: String,
    ) -> SpawnResult {
        var attributes: posix_spawnattr_t?
        var result = posix_spawnattr_init(&attributes)
        guard result == 0 else { return .failure(result) }
        defer { posix_spawnattr_destroy(&attributes) }

        // Establish the session atomically during spawn so descendants cannot
        // start before the shell has been isolated from attic's process group.
        result = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        guard result == 0 else { return .failure(result) }

        let arguments = [shellPath, "-c", command]
        let environmentEntries = environment.map { "\($0.key)=\($0.value)" }
        var processID: pid_t = 0
        result = withCStringArray(arguments) { argumentPointers in
            withCStringArray(environmentEntries) { environmentPointers in
                shellPath.withCString { executablePath in
                    posix_spawn(
                        &processID,
                        executablePath,
                        nil,
                        &attributes,
                        argumentPointers,
                        environmentPointers,
                    )
                }
            }
        }
        return result == 0 ? .success(processID) : .failure(result)
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result,
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    private static func waitForProcessGroupExit(
        processGroupID: pid_t,
        timeout: TimeInterval,
    ) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while processGroupExists(processGroupID) {
            guard DispatchTime.now() < deadline else { return false }
            usleep(10000)
        }
        return true
    }

    private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        if kill(-processGroupID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func terminationStatus(from rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7F
        return signal == 0 ? (rawStatus >> 8) & 0xFF : signal
    }
}

private final class ChildProcessWaiter: @unchecked Sendable {
    let exited = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var status: Int32?

    init(processID: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var rawStatus: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(processID, &rawStatus, 0)
            } while result == -1 && errno == EINTR

            self.lock.lock()
            if result == processID {
                self.status = rawStatus
            }
            self.lock.unlock()
            self.exited.signal()
        }
    }

    var rawStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}
