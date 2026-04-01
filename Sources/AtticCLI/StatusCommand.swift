import ArgumentParser
import AtticCore
import LadderKit

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show backup progress — how many assets are backed up vs pending.",
    )

    func run() async throws {
        let (config, _, manifestStore) = try Dependencies.makeBackupDeps()
        let manifest = try await Dependencies.loadManifest(store: manifestStore)
        let assets = Dependencies.loadAssets()

        // Single-pass counting
        var backedUpPhotos = 0, backedUpVideos = 0, pendingPhotos = 0, pendingVideos = 0
        var backedUpBytes = 0
        for asset in assets {
            if manifest.isBackedUp(asset.uuid) {
                if asset.kind == .photo { backedUpPhotos += 1 } else { backedUpVideos += 1 }
                backedUpBytes += manifest.entries[asset.uuid]?.size ?? 0
            } else {
                if asset.kind == .photo { pendingPhotos += 1 } else { pendingVideos += 1 }
            }
        }
        let backedUpCount = backedUpPhotos + backedUpVideos
        let pendingCount = pendingPhotos + pendingVideos

        let pct = assets.isEmpty ? 100.0 : Double(backedUpCount) / Double(assets.count) * 100

        print("Attic Backup Status")
        print("====================")
        print("Bucket:        \(config.bucket)")
        print("Completion:    \(String(format: "%.1f", pct))%")
        print("")
        print("Backed up:     \(backedUpCount) (\(formatBytes(backedUpBytes)))")
        print("  Photos:      \(backedUpPhotos)")
        print("  Videos:      \(backedUpVideos)")
        print("")
        print("Pending:       \(pendingCount)")
        print("  Photos:      \(pendingPhotos)")
        print("  Videos:      \(pendingVideos)")
        print("")
        print("Manifest:      \(manifest.entries.count) entries")
    }
}
