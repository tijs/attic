@testable import AtticCLI
@testable import AtticCore
import Foundation
import Testing

private actor RestoreMockImporter: PhotosImportProviding {
    enum Behavior { case success, duplicate, denied, uncertain, cancelled }
    var behavior: Behavior = .success
    var imported: [URL] = []
    var prepared = 0
    var identity = "disposable-library"
    var replaceDuringPrepare = false
    func replaceOnPrepare() { replaceDuringPrepare = true }
    func set(_ behavior: Behavior) { self.behavior = behavior }
    func libraryIdentity(for library: URL) async throws -> String { identity }
    func prepare(library: URL) async throws {
        prepared += 1
        if replaceDuringPrepare { identity = "replacement-library" }
        if behavior == .denied { throw RestoreError.invalid("Permission denied") }
    }

    func importFile(_ file: URL, library: URL) async throws -> [String] {
        imported.append(file)
        switch behavior {
        case .success: return ["imported/L0/001"]
        case .duplicate: return []
        case .denied: throw RestoreError.invalid("Permission denied")
        case .uncertain: throw RestoreError.invalid("Lost response")
        case .cancelled: throw CancellationError()
        }
    }
}

struct RestoreImportTests {
    @Test(arguments: [false, true])
    func importsAreOptInDurableAndDuplicateAware(duplicate: Bool) async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = RestoreMockImporter()
        if duplicate { await importer.set(.duplicate) }
        let options = RestorePhotosOptions(library: URL(fileURLWithPath: "/disposable.photoslibrary"))
        let filesOnly = try await runRestore(plan: plan, source: source, destination: root)
        #expect(filesOnly.restored == 1)
        #expect(await importer.imported.isEmpty)
        let imported = try await runRestore(
            plan: plan,
            source: source,
            destination: root,
            photos: options,
            importer: importer,
        )
        #expect(imported.skipped == 1)
        #expect(imported.imported == 1)
        let resumed = try await runRestore(
            plan: plan,
            source: source,
            destination: root,
            photos: options,
            importer: importer,
        )
        #expect(resumed.imported == 0)
        #expect(await importer.imported.count == 1)
        let journal = try RestoreJournalStore(directory: SafeDirectory(url: root), sourceID: "fixture")
        let record = try #require(try await journal.record(for: plan.items[0]))
        #expect(record.importState == "imported")
        #expect(record.importedIDs == (duplicate ? [] : ["imported/L0/001"]))
    }

    @Test func permissionFailureLeavesValidFilesAndCanRetryWithoutDuplicateRisk() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = RestoreMockImporter()
        await importer.set(.denied)
        let options = RestorePhotosOptions(library: URL(fileURLWithPath: "/disposable.photoslibrary"))
        let report = try await runRestore(
            plan: plan,
            source: source,
            destination: root,
            photos: options,
            importer: importer,
        )
        #expect(report.restored == 1)
        #expect(report.importFailed == 1)
        #expect(await importer.imported.isEmpty)
        await importer.set(.success)
        #expect(try await runRestore(plan: plan, source: source, destination: root, photos: options, importer: importer)
            .imported == 1)
    }

    @Test(arguments: [false, true])
    func uncertainAndCancelledImportsRequireExplicitRetry(cancelled: Bool) async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = RestoreMockImporter()
        await importer.set(cancelled ? .cancelled : .uncertain)
        let library = URL(fileURLWithPath: "/disposable.photoslibrary")
        let options = RestorePhotosOptions(library: library)
        if cancelled {
            await #expect(throws: CancellationError.self) {
                try await runRestore(plan: plan, source: source, destination: root, photos: options, importer: importer)
            }
        } else {
            #expect(try await runRestore(
                plan: plan,
                source: source,
                destination: root,
                photos: options,
                importer: importer,
            ).importUncertain == 1)
        }
        await importer.set(.success)
        let resumed = try await runRestore(
            plan: plan,
            source: source,
            destination: root,
            photos: options,
            importer: importer,
        )
        #expect(resumed.importUncertain == 1)
        #expect(await importer.imported.count == 1)
        let retry = RestorePhotosOptions(library: library, retryUncertain: true)
        #expect(try await runRestore(plan: plan, source: source, destination: root, photos: retry, importer: importer)
            .imported == 1)
        #expect(await importer.imported.count == 2)
    }

    @Test func replacedLibraryDuringPreparationCannotReceiveImportIntent() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "fixture")
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = RestoreMockImporter()
        await importer.replaceOnPrepare()
        let options = RestorePhotosOptions(library: URL(fileURLWithPath: "/disposable.photoslibrary"))
        let result = try await runRestore(
            plan: plan,
            source: source,
            destination: root,
            photos: options,
            importer: importer,
        )
        #expect(result.restored == 1)
        #expect(result.importFailed == 1)
        #expect(await importer.imported.isEmpty)
    }

    @Test func librarySelectionMustBeUniqueAndExactAndCLIRequiresExplicitDestination() throws {
        #expect(PhotosLibraryImporter.selectionMatches(
            database: "/selected/database/Photos.sqlite",
            output: "p123\nn/selected/database/Photos.sqlite\n",
        ))
        #expect(!PhotosLibraryImporter.selectionMatches(
            database: "/selected/database/Photos.sqlite",
            output: "n/other/database/Photos.sqlite\n",
        ))
        #expect(!PhotosLibraryImporter.selectionMatches(
            database: "/selected/database/Photos.sqlite",
            output: "n/selected/database/Photos.sqlite\nn/other/database/Photos.sqlite\n",
        ))
        #expect(throws: (any Error).self) { try RestoreCommand.parse([]) }
        let command = try RestoreCommand.parse([
            "--destination",
            "/tmp/recovery",
            "--profile",
            "external",
            "--dry-run",
            "--request-archive",
        ])
        #expect(command.dryRun)
        #expect(command.requestArchive)
        #expect(command.source.profile == "external")
        #expect(throws: (any Error).self) { try RestoreCommand.utcDay("2024-02-30") }
    }
}
