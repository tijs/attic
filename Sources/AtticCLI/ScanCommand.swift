import ArgumentParser
import AtticCore
import LadderKit

struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan your Photos library and show a summary.",
    )

    func run() async throws {
        let assets = Dependencies.loadAssets()

        if assets.isEmpty {
            print("No assets found in Photos library.")
            return
        }

        let photos = assets.filter { $0.kind == .photo }
        let videos = assets.filter { $0.kind == .video }

        print("Photos Library Scan")
        print("===================")
        print("Total assets:  \(assets.count)")
        print("  Photos:      \(photos.count)")
        print("  Videos:      \(videos.count)")

        // Group by UTI
        var utiCounts: [String: Int] = [:]
        for asset in assets {
            let uti = asset.uniformTypeIdentifier ?? "unknown"
            utiCounts[uti, default: 0] += 1
        }
        let topUTIs = utiCounts.sorted { $0.value > $1.value }.prefix(10)

        print("")
        print("Top file types:")
        for (uti, count) in topUTIs {
            print("  \(uti): \(count)")
        }

        // Favorites + edited
        let favorites = assets.filter(\.isFavorite).count
        let edited = assets.filter(\.hasEdit).count
        print("")
        print("Favorites:     \(favorites)")
        print("Edited:        \(edited)")
    }
}
