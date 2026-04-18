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
        do {
            try await exporter.checkPermissions()
        } catch AppleScriptError.automationPermissionDenied {
            throw ExportProviderError.permissionDenied(
                AppleScriptError.automationPermissionDenied.localizedDescription
            )
        } catch let err as AppleScriptError {
            if case .timeout(_, let seconds) = err {
                throw ExportProviderError.timeout(seconds: Int(seconds))
            }
            throw err
        }
    }
}
