import AtticCore
import Foundation
import LadderKit

/// Bridges LadderKit's PhotoExporter to AtticCore's ExportProviding protocol.
struct LadderKitExportProvider: ExportProviding {
    private let exporter: PhotoExporter
    private let localAvailability: (any LocalAvailabilityProviding)?
    private let adaptiveController: (any AdaptiveConcurrencyControlling)?

    init(
        stagingDir: URL,
        library: PhotoLibrary = PhotoKitLibrary(),
        localAvailability: (any LocalAvailabilityProviding)? = nil,
        adaptiveController: (any AdaptiveConcurrencyControlling)? = nil,
    ) {
        exporter = PhotoExporter(
            stagingDir: stagingDir,
            library: library,
            scriptExporter: AppleScriptRunner(),
        )
        self.localAvailability = localAvailability
        self.adaptiveController = adaptiveController
    }

    func exportBatch(uuids: [String]) async throws -> ExportResponse {
        await exporter.export(
            uuids: uuids,
            localAvailability: localAvailability,
            adaptiveController: adaptiveController,
        )
    }

    func checkPermissions() async throws {
        try await exporter.checkPermissions()
    }
}
