@testable import AtticCore
import Foundation
import Testing

struct RestorePlannerTests {
    @Test func datesWithFractionalSecondsOffsetsTypeAndExactAlbumIDs() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture()
        let from = Date(timeIntervalSince1970: 1_705_276_800) // 2024-01-15 UTC
        let selected = try await planRestore(
            manifest: manifest, source: source, sourceID: "fixture",
            filters: RestoreFilters(
                from: from,
                before: from.addingTimeInterval(86400),
                type: "photo",
                album: "album-1",
            ),
        )
        #expect(selected.items.count == 2)
        let excluded = try await planRestore(
            manifest: manifest, source: source, sourceID: "fixture", filters: RestoreFilters(type: "video"),
        )
        #expect(excluded.items.isEmpty)
    }

    @Test func missingOrCorruptMetadataCannotSilentlyExcludeFilteredResources() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let entry = try #require(manifest.entries.values.first)
        let key = try S3Paths.metadataKey(uuid: entry.uuid)
        for data in [Data(), Data("{}".utf8)] {
            await source.set(data, key: key)
            await #expect(throws: RestoreError.self) {
                try await planRestore(
                    manifest: manifest,
                    source: source,
                    sourceID: "fixture",
                    filters: RestoreFilters(album: "x"),
                )
            }
            let unfiltered = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
            #expect(unfiltered.items.count == 1)
            #expect(unfiltered.metadataWarnings == 1)
        }
        await source.remove(key)
        await #expect(throws: RestoreError.self) {
            try await planRestore(
                manifest: manifest,
                source: source,
                sourceID: "fixture",
                filters: RestoreFilters(type: "photo"),
            )
        }
        #expect(await source.downloads.isEmpty)
    }

    @Test(arguments: ["sha1:abc", "sha256:bad", "", "md5:ab"])
    func unsupportedChecksumsFailBeforeAnyDownload(checksum: String) async throws {
        let (source, original) = try RestoreTestSupport.fixture(count: 1)
        var manifest = original
        let uuid = try #require(manifest.entries.keys.first)
        manifest.entries[uuid]?.checksum = checksum
        await #expect(throws: RestoreError.self) { try await planRestore(
            manifest: manifest,
            source: source,
            sourceID: "fixture",
        ) }
        #expect(await source.downloads.isEmpty)
    }

    @Test(arguments: [
        "originals/a%",
        "originals/a%2X.heic",
        "originals/../escape",
        "originals/%2E%2E/escape",
        "/originals/a",
    ])
    func malformedKeysFailBeforeTransport(key: String) async throws {
        let (source, original) = try RestoreTestSupport.fixture(count: 1)
        var manifest = original
        let uuid = try #require(manifest.entries.keys.first)
        manifest.entries[uuid]?.s3Key = key
        await #expect(throws: RestoreError.self) { try await planRestore(
            manifest: manifest,
            source: source,
            sourceID: "fixture",
        ) }
    }

    @Test func duplicateReferencesDownloadEachStoredResourceOnce() async throws {
        let (source, original) = try RestoreTestSupport.fixture(count: 1)
        var manifest = original
        var alias = try #require(manifest.entries.values.first)
        alias.uuid = "alias"
        manifest.entries[alias.uuid] = alias
        // No metadata for alias: unfiltered recovery keeps it and deduplicates the original.
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        #expect(plan.items.count == 1)
        #expect(plan.items[0].uuids.count == 2)
        #expect(plan.metadataWarnings == 1)
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await runRestore(plan: plan, source: source, destination: root).restored == 1)
        #expect(await source.downloads.values.reduce(0, +) == 1)
    }
}
