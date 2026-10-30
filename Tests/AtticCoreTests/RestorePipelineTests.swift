@testable import AtticCore
import Foundation
import Testing

struct RestorePipelineTests {
    @Test(arguments: [1, 2])
    func originalBytesRestoreAndResumeWithoutSourceWrites(version: Int) async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(version: version)
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        #expect(plan.items.count == 2)
        #expect(Set(plan.items.map(\.relativePath)).count == 2)
        let result = try await runRestore(plan: plan, source: source, destination: root, concurrency: 1)
        #expect(result.restored == 2)
        #expect(result.successful)
        let resumed = try await runRestore(plan: plan, source: source, destination: root)
        #expect(resumed.skipped == 2)
        #expect(resumed.restored == 0)
        #expect(await source.downloads.values.reduce(0, +) == 2)
        #expect(await source.mutations == 0)
        let directory = try SafeDirectory(url: root)
        for item in plan.items {
            let file = try #require(try directory.reader(key: item.relativePath))
            defer { try? file.close() }
            #expect(try SafeDirectory.digest(file).checksum == item.checksum)
            #expect(try directory.head(key: "metadata/\(item.id).json") != nil)
        }
    }

    @Test(arguments: [RestoreFixtureSource.DownloadMode.corrupt, .truncated, .missing])
    func incompleteDownloadLeavesNoOriginalAndCanResume(mode: RestoreFixtureSource.DownloadMode) async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        let item = try #require(plan.items.first)
        await source.mode(mode, for: item.key)
        let failed = try await runRestore(plan: plan, source: source, destination: root)
        #expect(failed.failed == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(item.relativePath).path))
        await source.mode(.normal, for: item.key)
        #expect(try await runRestore(plan: plan, source: source, destination: root).restored == 1)
        #expect(await source.mutations == 0)
    }

    @Test func modifiedExistingFileIsPreservedEvenWhenJournalSaysComplete() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        _ = try await runRestore(plan: plan, source: source, destination: root)
        let item = try #require(plan.items.first)
        let file = root.appendingPathComponent(item.relativePath)
        try Data("unrelated file".utf8).write(to: file)
        #expect(try await runRestore(plan: plan, source: source, destination: root).failed == 1)
        #expect(try Data(contentsOf: file) == Data("unrelated file".utf8))
        #expect(await source.downloads[item.key] == 1)
        try FileManager.default.removeItem(at: file)
        #expect(try await runRestore(plan: plan, source: source, destination: root).restored == 1)
    }

    @Test func journalProvenanceAndCorruptionAreFatal() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        _ = try await runRestore(plan: plan, source: source, destination: root)
        let other = try await planRestore(manifest: manifest, source: source, sourceID: "another-bucket")
        await #expect(throws: RestoreError.self) { try await runRestore(plan: other, source: source, destination: root)
        }
        try Data("broken journal".utf8).write(to: root.appendingPathComponent(".attic-restore.json"))
        await #expect(throws: (any Error).self) { try await runRestore(plan: plan, source: source, destination: root) }
    }

    @Test func partialSuccessBoundedConcurrencyCancellationAndEmptySelection() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 5)
        let root = try RestoreTestSupport.directory()
        let emptyRoot = try RestoreTestSupport.directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: emptyRoot)
        }
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture", concurrency: 2)
        await source.mode(.missing, for: plan.items[0].key)
        let result = try await runRestore(plan: plan, source: source, destination: root, concurrency: 2)
        #expect(result.restored == 4)
        #expect(result.failed == 1)
        #expect(await source.maximumActive <= 2)
        await source.mode(.cancelled, for: plan.items[0].key)
        await #expect(throws: CancellationError.self) { try await runRestore(
            plan: plan,
            source: source,
            destination: root,
        ) }
        let empty = try await planRestore(
            manifest: manifest, source: source, sourceID: "fixture", filters: RestoreFilters(album: "absent"),
        )
        #expect(empty.items.isEmpty)
        #expect(try await runRestore(plan: empty, source: source, destination: emptyRoot).successful)
    }

    @Test func knownSidecarsRefreshWhenMetadataBecomesAvailable() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let entry = try #require(manifest.entries.values.first)
        let key = try S3Paths.metadataKey(uuid: entry.uuid)
        let metadata = try await source.getObject(key: key)
        await source.remove(key)
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(plan.metadataWarnings == 1)
        _ = try await runRestore(plan: plan, source: source, destination: root)
        await source.set(metadata, key: key)
        let refreshed = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        #expect(refreshed.metadataWarnings == 0)
        #expect(try await runRestore(plan: refreshed, source: source, destination: root).skipped == 1)
        #expect(await source.downloads.values.reduce(0, +) == 1)
        let sidecar = root.appendingPathComponent("metadata/\(refreshed.items[0].id).json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        raw["sourceID"] = "unrelated"
        let unrelated = try JSONSerialization.data(withJSONObject: raw)
        try unrelated.write(to: sidecar)
        #expect(try await runRestore(plan: refreshed, source: source, destination: root).failed == 1)
        #expect(try Data(contentsOf: sidecar) == unrelated)
    }

    @Test func symlinkedOutputTreeCannotEscape() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let root = try RestoreTestSupport.directory()
        let outside = try RestoreTestSupport.directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("files"),
            withDestinationURL: outside,
        )
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        #expect(try await runRestore(plan: plan, source: source, destination: root).failed == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
