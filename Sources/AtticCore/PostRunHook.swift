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

    /// Run `command` via `sh -c` with `environment` merged over the current
    /// process environment. Returns the hook's exit status, or nil if the
    /// hook could not be launched. Hook outcomes never affect attic's own
    /// exit code — a broken notifier should not mask a successful backup.
    @discardableResult
    public static func run(
        command: String,
        environment: [String: String],
        shellPath: String = "/bin/sh",
    ) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, new in new }

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data(
                "Warning: post-run hook failed to launch: \(error)\n".utf8,
            ))
            return nil
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            FileHandle.standardError.write(Data(
                "Warning: post-run hook exited with status \(process.terminationStatus)\n".utf8,
            ))
        }
        return process.terminationStatus
    }
}
