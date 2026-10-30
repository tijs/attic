import Foundation

/// Import is an independent opt-in side effect, after verified file recovery.
public protocol PhotosImportProviding: Sendable {
    func libraryIdentity(for library: URL) async throws -> String
    func prepare(library: URL) async throws
    func importFile(_ file: URL, library: URL) async throws -> [String]
}

public struct RestorePhotosOptions: Sendable {
    public let library: URL
    public let retryUncertain: Bool
    public init(library: URL, retryUncertain: Bool = false) {
        self.library = library
        self.retryUncertain = retryUncertain
    }
}

func importRestoredPhotos(
    items: [RestoreItem],
    directory: SafeDirectory,
    journal: RestoreJournalStore,
    options: RestorePhotosOptions,
    importer: any PhotosImportProviding,
    report: inout RestoreReport,
) async throws {
    let identity: String
    do {
        identity = try await importer.libraryIdentity(for: options.library)
        guard !identity.isEmpty, identity.count <= 512 else { throw RestoreError.invalid("Invalid library identity") }
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        report.importFailed += items.count
        if report.errors.count < 20 { report.errors.append("Cannot validate the selected Photos library") }
        return
    }
    let pending = try await pendingImports(
        items,
        journal: journal,
        identity: identity,
        options: options,
        report: &report,
    )
    guard !pending.isEmpty else { return }
    do {
        try await importer.prepare(library: options.library)
        try await verifyImportLibrary(importer, library: options.library, identity: identity)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        report.importFailed += pending.count
        if report.errors
            .count < 20 { report.errors.append("Photos import preparation failed; recovered files remain valid") }
        return
    }
    for item in pending {
        try Task.checkCancellation()
        try await verifyImportLibrary(importer, library: options.library, identity: identity)
        try verifyImportOriginal(item, directory: directory)
        // Persist intent before sending any import event. A crash/cancellation after
        // this point is uncertain and cannot automatically repeat the side effect.
        try await journal.importOutcome(item, library: identity, state: "pending")
        do {
            let file = directory.url.appendingPathComponent(item.relativePath)
            let ids = try await importer.importFile(file, library: options.library)
            guard ids.count <= 100, ids.allSatisfy({ S3Paths.isValidUUID($0) && $0.count <= 512 }) else {
                throw RestoreError.invalid("Unexpected Photos import identifiers")
            }
            try await journal.importOutcome(item, library: identity, state: "imported", ids: ids)
            report.imported += 1
        } catch is CancellationError {
            // The durable pending record is intentionally retained.
            throw CancellationError()
        } catch {
            try await journal.importOutcome(item, library: identity, state: "uncertain")
            report.importUncertain += 1
            if report.errors
                .count < 20 { report.errors.append("Photos import outcome is uncertain; explicit retry required") }
        }
    }
}

private func pendingImports(
    _ items: [RestoreItem], journal: RestoreJournalStore, identity: String,
    options: RestorePhotosOptions, report: inout RestoreReport,
) async throws -> [RestoreItem] {
    var pending: [RestoreItem] = []
    for item in items {
        guard let record = try await journal.record(for: item) else { continue }
        if let previous = record.importLibrary, previous != identity {
            throw RestoreError.invalid("Restore journal is bound to a different Photos library")
        }
        if record.importState == "imported" { continue }
        if ["pending", "uncertain"].contains(record.importState ?? ""), !options.retryUncertain {
            report.importUncertain += 1
        } else {
            pending.append(item)
        }
    }
    return pending
}

private func verifyImportLibrary(_ importer: any PhotosImportProviding, library: URL, identity: String) async throws {
    guard try await importer.libraryIdentity(for: library) == identity else {
        throw RestoreError.invalid("Selected Photos library changed before import")
    }
}

private func verifyImportOriginal(_ item: RestoreItem, directory: SafeDirectory) throws {
    guard let file = try directory.reader(key: item.relativePath) else {
        throw RestoreError.invalid("Verified original disappeared before Photos import")
    }
    defer { try? file.close() }
    let digest = try SafeDirectory.digest(file)
    guard digest.checksum == item.checksum, item.expectedSize == nil || item.expectedSize == digest.size else {
        throw RestoreError.invalid("Original changed before Photos import")
    }
}
