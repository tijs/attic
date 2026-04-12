import ArgumentParser
import AtticCore
import Foundation

struct ViewerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "viewer",
        abstract: "Browse backed-up photos in your browser."
    )

    @Option(name: .long, help: "Port to bind to (0 for automatic).")
    var port: Int = 0

    func run() async throws {
        let (_, s3, manifestStore) = try Dependencies.makeBackupDeps()
        let manifest = try await Dependencies.loadManifest(store: manifestStore)

        if manifest.entries.isEmpty {
            print("No backed-up assets found. Run 'attic backup' first.")
            return
        }

        let dataStore = ViewerDataStore()
        let total = manifest.entries.count

        let spinner = PreparationSpinner()
        spinner.updateStatus("Loading metadata... 0 / \(formatCount(total)) assets")
        spinner.start()

        await dataStore.load(manifest: manifest, s3: s3) { loaded, total in
            spinner.updateStatus(
                "Loading metadata... \(formatCount(loaded)) / \(formatCount(total)) assets"
            )
        }

        spinner.stop()
        print("  Loaded \(formatCount(total)) assets")

        let thumbnailService = ThumbnailService(s3: s3, dataStore: dataStore)
        let server = ViewerServer(
            dataStore: dataStore, s3: s3,
            thumbnailProvider: thumbnailService, port: port
        )

        try await server.start { actualPort in
            let url = "http://127.0.0.1:\(actualPort)"
            print("  Viewer running at \(url)")
            print("  Press Ctrl+C to stop\n")
            openBrowser(url: url)
        }
    }
}

private func formatCount(_ n: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

private func openBrowser(url: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url]
    try? process.run()
}
