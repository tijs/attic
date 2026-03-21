import ArgumentParser
import AtticCore
import LadderKit

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show backup progress — how many assets are backed up vs pending."
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

        debugPrint("Attic Backup Status")
        debugPrint("====================")
        debugPrint("Bucket:        \(config.bucket)")
        debugPrint("Completion:    \(String(format: "%.1f", pct))%")
        debugPrint("")
        debugPrint("Backed up:     \(backedUpCount) (\(formatBytes(backedUpBytes)))")
        debugPrint("  Photos:      \(backedUpPhotos)")
        debugPrint("  Videos:      \(backedUpVideos)")
        debugPrint("")
        debugPrint("Pending:       \(pendingCount)")
        debugPrint("  Photos:      \(pendingPhotos)")
        debugPrint("  Videos:      \(pendingVideos)")
        debugPrint("")
        debugPrint("Manifest:      \(manifest.entries.count) entries")
    }
}
