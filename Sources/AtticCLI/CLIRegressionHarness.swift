#if DEBUG
    import ArgumentParser
    import AtticCore
    import Foundation
    import LadderKit

    /// Debug-only subprocess/PTY seams used by the real executable regression
    /// tests. Keeping them here prevents test fixtures from leaking into the
    /// normal backup flow or requiring public initializers from AtticCore.
    enum CLIRegressionHarness {
        static func backupOperation(
            fallback: @escaping @Sendable () async throws -> BackupReport,
        ) -> @Sendable () async throws -> BackupReport {
            if ProcessInfo.processInfo.environment["ATTIC_TEST_BLOCKING_BACKUP"] == "1" {
                return {
                    FileHandle.standardError.write(Data("ATTIC_TEST_BACKUP_READY\n".utf8))
                    try await Task.sleep(for: .seconds(30))
                    throw CancellationError()
                }
            }
            if ProcessInfo.processInfo.environment["ATTIC_TEST_RENDERER_SMOKE"] == "1" {
                return { try await runRendererSmoke() }
            }
            return fallback
        }

        static func signalHandlersInstalled() {
            guard ProcessInfo.processInfo.environment["ATTIC_TEST_SIGNAL_ARM_DELAY"] == "1" else {
                return
            }
            FileHandle.standardError.write(Data("ATTIC_TEST_SIGNAL_HANDLERS_INSTALLED\n".utf8))
            Thread.sleep(forTimeInterval: 0.3)
        }

        private static func runRendererSmoke() async throws -> BackupReport {
            guard isatty(STDOUT_FILENO) != 0 else {
                throw ExitCode.failure
            }

            let renderer = TerminalRenderer(tickInterval: nil)
            defer { renderer.finish() }
            renderer.backupStarted(pending: 1, photos: 1, videos: 0)
            renderer.assetStarting(
                uuid: "private",
                filename: "safe-🙂-東京-e\u{301}\u{1B}[999A\u{1B}]2;owned-title\u{7}.HEIC",
                size: 1,
            )
            FileHandle.standardError.write(Data("ATTIC_TEST_RENDERER_RESIZE_READY\n".utf8))
            try await Task.sleep(for: .milliseconds(300))
            renderer.backupPaused(reason: "offline\u{009D}owned-title\u{009C} now")
            renderer.backupResumed()
            renderer.diagnostic(message: "diag\u{1B}Pdevice-payload\u{1B}\\end")
            renderer.assetFailed(
                uuid: "private",
                filename: "failed-🙂-東京.HEIC",
                message: "provider\u{009B}20A error",
                classification: .other,
            )
            renderer.backupCompleted(uploaded: 0, failed: 1, totalBytes: 0)
            FileHandle.standardError.write(Data("ATTIC_TEST_RENDERER_COMPLETED\n".utf8))
            throw ExitCode.success
        }
    }
#endif
