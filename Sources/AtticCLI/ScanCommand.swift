import ArgumentParser
import AtticCore
import LadderKit

struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan your Photos library and show a summary."
    )

    func run() async throws {
        let assets = Dependencies.loadAssets()

        if assets.isEmpty {
            debugPrint("No assets found in Photos library.")
            return
        }

        let photos = assets.filter { $0.kind == .photo }
        let videos = assets.filter { $0.kind == .video }

        debugPrint("Photos Library Scan")
        debugPrint("===================")
        debugPrint("Total assets:  \(assets.count)")
        debugPrint("  Photos:      \(photos.count)")
        debugPrint("  Videos:      \(videos.count)")

        // Group by UTI
        var utiCounts: [String: Int] = [:]
        for asset in assets {
            let uti = asset.uniformTypeIdentifier ?? "unknown"
            utiCounts[uti, default: 0] += 1
        }
        let topUTIs = utiCounts.sorted { $0.value > $1.value }.prefix(10)

        debugPrint("")
        debugPrint("Top file types:")
        for (uti, count) in topUTIs {
            debugPrint("  \(uti): \(count)")
        }

        // Favorites + edited
        let favorites = assets.filter(\.isFavorite).count
        let edited = assets.filter(\.hasEdit).count
        debugPrint("")
        debugPrint("Favorites:     \(favorites)")
        debugPrint("Edited:        \(edited)")
    }
}
