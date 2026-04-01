import Foundation
import AtticCore
import LadderKit

/// Bridges LadderKit's PhotoExporter to AtticCore's ExportProviding protocol.
struct LadderKitExportProvider: ExportProviding {
    private let exporter: PhotoExporter

    init(stagingDir: URL, library: PhotoLibrary = PhotoKitLibrary()) {
        self.exporter = PhotoExporter(
            stagingDir: stagingDir,
            library: library,
            scriptExporter: AppleScriptRunner()
        )
    }

    func exportBatch(uuids: [String]) async throws -> ExportResponse {
        await exporter.export(uuids: uuids)
    }

    func checkPermissions() async throws {
        try await exporter.checkPermissions()
    }
}
