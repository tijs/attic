@testable import AtticCore
import Foundation
import Testing

private final class JournalWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var bytes = 0
    private var reject = false

    func inspectStaging(in root: URL) throws {
        let files = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey],
        ))
        var stagedBytes = 0
        for case let file as URL in files where file.lastPathComponent.hasPrefix(".attic-part-") {
            stagedBytes += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        try lock.withLock {
            if reject { throw RestoreError.invalid("Injected journal publication failure") }
            writes += 1
            bytes += stagedBytes
        }
    }

    func rejectWrites(_ value: Bool) { lock.withLock { reject = value } }
    var counts: (writes: Int, bytes: Int) {
        lock.withLock { (writes, bytes) }
    }
}

private struct JournalIntentImporter: PhotosImportProviding {
    let root: URL
    let item: RestoreItem

    func libraryIdentity(for library: URL) async throws -> String { "fixture-library" }
    func prepare(library: URL) async throws {}

    func importFile(_ file: URL, library: URL) async throws -> [String] {
        let disk = try RestoreJournalStore(directory: SafeDirectory(url: root), sourceID: "fixture")
        let record = try #require(try await disk.record(for: item))
        #expect(record.importState == "pending")
        #expect(record.importLibrary == "fixture-library")
        return ["imported/L0/001"]
    }
}

struct RestoreJournalTests {
    private func item(_ index: Int) -> RestoreItem {
        RestoreItem(
            key: "originals/2024/01/resource-\(index).heic",
            checksum: String(repeating: "a", count: 64), expectedSize: 1,
            uuids: ["resource-\(index)"], metadata: [], metadataWarnings: 0,
        )
    }

    @Test func journalWritesAreLinearAndUnchangedResumeWritesNothing() async throws {
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = JournalWriteProbe()
        let directory = try SafeDirectory(url: root, beforePublish: { try probe.inspectStaging(in: root) })
        let journal = try RestoreJournalStore(directory: directory, sourceID: "fixture")
        let items = (0 ..< 128).map(item)
        for item in items {
            try await journal.completed(item, size: 1)
        }

        // Measure actual staged bytes, not elapsed time: a growing snapshot per
        // resource exceeds this generous constant budget per completion.
        #expect(probe.counts.bytes > 0)
        #expect(probe.counts.bytes < 2048 * (items.count + 1))
        let beforeResume = probe.counts
        let resumed = try RestoreJournalStore(directory: directory, sourceID: "fixture")
        try await resumed.validate(items)
        for item in items {
            try await resumed.completed(item, size: 1)
        }
        #expect(probe.counts.writes == beforeResume.writes)
        #expect(probe.counts.bytes == beforeResume.bytes)
    }

    @Test func legacySnapshotUpgradesOnceAndIncrementalImportStateWinsOnReopen() async throws {
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = JournalWriteProbe()
        let directory = try SafeDirectory(url: root, beforePublish: { try probe.inspectStaging(in: root) })
        let resource = item(0)
        let legacy = RestoreJournalRecord(
            key: resource.key, checksum: resource.checksum, size: 1,
            importState: "pending", importLibrary: "fixture-library",
        )
        let encodedRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
        let snapshot = try JSONSerialization.data(withJSONObject: [
            "version": 1, "sourceID": "fixture", "records": [resource.id: encodedRecord],
        ])
        try directory.write(key: ".attic-restore.json", body: snapshot, replace: false)
        let beforeUpgrade = probe.counts.writes
        let journal = try RestoreJournalStore(directory: directory, sourceID: "fixture")
        #expect(probe.counts.writes == beforeUpgrade + 1)
        #expect(try await journal.record(for: resource)?.importState == "pending")
        let header = try #require(try directory.readIfPresent(key: ".attic-restore.json"))
        let object = try #require(JSONSerialization.jsonObject(with: header) as? [String: Any])
        #expect(object["version"] as? Int == 2)
        try await journal.completed(resource, size: 1)
        #expect(probe.counts.writes == beforeUpgrade + 1)
        try await journal.importOutcome(resource, library: "fixture-library", state: "imported", ids: ["new-id"])
        #expect(try directory.readIfPresent(key: ".attic-restore.json") == header)
        let afterImport = probe.counts.writes
        let reopened = try RestoreJournalStore(directory: directory, sourceID: "fixture")
        let restored = try #require(try await reopened.record(for: resource))
        #expect(restored.importState == "imported")
        #expect(restored.importedIDs == ["new-id"])
        #expect(probe.counts.writes == afterImport)
    }

    @Test func failedPublicationDoesNotChangeCachedOrPersistedState() async throws {
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = JournalWriteProbe()
        let directory = try SafeDirectory(url: root, beforePublish: { try probe.inspectStaging(in: root) })
        let journal = try RestoreJournalStore(directory: directory, sourceID: "fixture")
        let resource = item(0)
        probe.rejectWrites(true)
        await #expect(throws: RestoreError.self) { try await journal.completed(resource, size: 1) }
        #expect(try await journal.record(for: resource) == nil)
        probe.rejectWrites(false)
        try await journal.completed(resource, size: 1)
        probe.rejectWrites(true)
        await #expect(throws: RestoreError.self) {
            try await journal.importOutcome(resource, library: "fixture-library", state: "pending")
        }
        #expect(try await journal.record(for: resource)?.importState == nil)
        let disk = try RestoreJournalStore(directory: directory, sourceID: "fixture")
        #expect(try await disk.record(for: resource)?.importState == nil)
        probe.rejectWrites(false)
        try await journal.importOutcome(resource, library: "fixture-library", state: "pending")
        let reopened = try RestoreJournalStore(directory: directory, sourceID: "fixture")
        #expect(try await reopened.record(for: resource)?.importState == "pending")
    }

    @Test(arguments: ["corrupt", "source", "schema"])
    func invalidIncrementalRecordsAreRejectedBeforeUse(failure: String) async throws {
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try SafeDirectory(url: root)
        let resource = item(0)
        let journal = try RestoreJournalStore(directory: directory, sourceID: "fixture")
        try await journal.completed(resource, size: 1)
        let key = ".attic-restore-records/\(resource.id).json"
        var data = try #require(try directory.readIfPresent(key: key))
        if failure == "corrupt" {
            data = Data("broken record".utf8)
        } else {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if failure == "source" {
                object["sourceID"] = "another-backup"
            } else {
                object["version"] = 999
            }
            data = try JSONSerialization.data(withJSONObject: object)
        }
        try directory.write(key: key, body: data, replace: true)
        let reopened = try RestoreJournalStore(directory: directory, sourceID: "fixture")
        await #expect(throws: (any Error).self) { try await reopened.validate([resource]) }
    }

    @Test func importIntentIsDurableBeforeCallingImporter() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        let resource = try #require(plan.items.first)
        let report = try await runRestore(
            plan: plan, source: source, destination: root,
            photos: RestorePhotosOptions(library: URL(fileURLWithPath: "/fixture.photoslibrary")),
            importer: JournalIntentImporter(root: root, item: resource),
        )
        #expect(report.imported == 1)
        let disk = try RestoreJournalStore(directory: SafeDirectory(url: root), sourceID: "fixture")
        #expect(try await disk.record(for: resource)?.importedIDs == ["imported/L0/001"])
    }
}
