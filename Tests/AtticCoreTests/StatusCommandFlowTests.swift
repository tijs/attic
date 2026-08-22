@testable import AtticCLI
@testable import AtticCore
import Foundation
import LadderKit
import Testing

/// CLI-level coverage of `StatusCommand.buildDashboard` — the orchestration
/// behind `attic status` — using injected loaders instead of real config,
/// S3, or PhotoKit.
struct StatusCommandFlowTests {
    @Test func unconfiguredStatusEmitsLibraryOnlyJSON() async throws {
        // Before `attic init`, both the migration guard and the backup
        // context throw `notInitialized`. Status must still produce a
        // library-only dashboard that serializes to valid JSON.
        let data = try await StatusCommand.buildDashboard(
            ensureMigrated: { throw CLIError.notInitialized },
            loadAssets: { [makeTestAsset(uuid: "A")] },
            loadLocalAvailability: { nil },
            loadRetryQueue: { nil },
            loadBackupContext: { throw CLIError.notInitialized },
        )

        let parsed = try #require(
            try JSONSerialization.jsonObject(with: formatDashboardJSON(data)) as? [String: Any],
        )

        let library = try #require(parsed["library"] as? [String: Any])
        #expect(library["photos"] as? Int == 1)
        #expect(parsed["backup"] == nil)
        #expect(parsed["s3"] == nil)
        #expect(parsed["retry"] == nil)
    }

    @Test func statusStillFailsWhenMigrationIsDeclined() async throws {
        // Only `notInitialized` is tolerated — a required-but-unrun
        // migration must keep aborting the command.
        await #expect(throws: CLIError.self) {
            _ = try await StatusCommand.buildDashboard(
                ensureMigrated: { throw CLIError.migrationRequired },
                loadAssets: { [] },
                loadLocalAvailability: { nil },
                loadRetryQueue: { nil },
                loadBackupContext: { throw CLIError.notInitialized },
            )
        }
    }
}
