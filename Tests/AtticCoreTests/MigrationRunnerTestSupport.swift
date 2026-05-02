@testable import AtticCore
import Foundation
import LadderKit

/// Shared test fixtures for `MigrationRunner` test suites. Extracted into a
/// support file so individual test files stay under SwiftLint's 600-line cap.
enum MigrationRunnerTestSupport {
    actor MockResolver: CloudIdentityResolving {
        private var mappings: [String: CloudMappingResult]
        private(set) var calls: Int = 0

        init(_ mappings: [String: CloudMappingResult]) {
            self.mappings = mappings
        }

        nonisolated func resolve(localIdentifiers: [String]) async -> [String: CloudMappingResult] {
            await tick()
            return await read(localIdentifiers)
        }

        private func tick() { calls += 1 }
        private func read(_ ids: [String]) -> [String: CloudMappingResult] {
            var out: [String: CloudMappingResult] = [:]
            for id in ids { out[id] = mappings[id] ?? .notFound }
            return out
        }
    }

    final class InMemoryRetryStore: RetryQueueProviding, @unchecked Sendable {
        var queue: RetryQueue?
        func load() -> RetryQueue? { queue }
        func save(_ q: RetryQueue) throws { queue = q }
        func clear() throws { queue = nil }
    }

    final class InMemoryUnavailableStore: UnavailableAssetStoring, @unchecked Sendable {
        var assets: UnavailableAssets = .init()
        func load() -> UnavailableAssets { assets }
        func save(_ a: UnavailableAssets) throws { assets = a }
    }

    static func v1ManifestData(entries: [(uuid: String, key: String)]) throws -> Data {
        var dict: [String: ManifestEntry] = [:]
        for e in entries {
            dict[e.uuid] = ManifestEntry(
                uuid: e.uuid,
                s3Key: e.key,
                checksum: "sha256:\(e.uuid)",
                backedUpAt: "2024-01-01T00:00:00Z",
            )
        }
        let manifest = Manifest(version: 1, entries: dict)
        return try manifest.encoded()
    }

    static func metadataJSON(uuid: String, s3Key: String) -> Data {
        let json = """
        {
            "uuid": "\(uuid)",
            "originalFilename": "IMG.HEIC",
            "width": 1, "height": 1,
            "favorite": false, "hasEdit": false,
            "albums": [], "keywords": [], "people": [],
            "s3Key": "\(s3Key)",
            "checksum": "sha256:\(uuid)",
            "backedUpAt": "2024-01-01T00:00:00Z"
        }
        """
        return Data(json.utf8)
    }

    static func makeRunner(
        s3: MockS3Provider,
        resolver: MockResolver,
        library: [(bareUUID: String, fullLocalIdentifier: String)],
        retryStore: InMemoryRetryStore = InMemoryRetryStore(),
        unavailableStore: InMemoryUnavailableStore = InMemoryUnavailableStore(),
    ) -> MigrationRunner {
        MigrationRunner(
            s3: s3,
            manifestStore: S3ManifestStore(s3: s3),
            resolver: resolver,
            assetIdentifierProvider: { library },
            retryStore: retryStore,
            unavailableStore: unavailableStore,
        )
    }
}
