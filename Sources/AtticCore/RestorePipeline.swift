import Foundation

private struct RestoreSidecar: Codable {
    var schemaVersion = 1
    let sourceID: String
    let original: RestoreItem
}

private enum RestoreItemResult: Sendable {
    case restored(RestoreItem, Int64)
    case skipped(RestoreItem)
    case failed(String)
    case pending
}

/// Originals are verified before atomic publication. The backup is only read.
public func runRestore(
    plan: RestorePlan,
    source: any ObjectDownloading,
    destination: URL,
    concurrency: Int = 4,
    archive: RestoreArchiveOptions = RestoreArchiveOptions(),
    photos: RestorePhotosOptions? = nil,
    importer: (any PhotosImportProviding)? = nil,
) async throws -> RestoreReport {
    guard (1 ... 16).contains(concurrency), (photos == nil) == (importer == nil) else {
        throw RestoreError.invalid("Invalid concurrency or Photos import configuration")
    }
    try archive.validate()
    let archiveDeadline = ProcessInfo.processInfo.systemUptime + archive.waitSeconds
    if let filesystem = source as? FilesystemObjectStore {
        let sourcePath = filesystem.directory.url.path.lowercased()
        let targetPath = destination.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        guard targetPath != sourcePath, !targetPath.hasPrefix(sourcePath + "/") else {
            throw RestoreError.invalid("Recovery destination must be outside the filesystem backup source")
        }
    }
    let directory = try SafeDirectory(url: destination)
    let writerLock = try DirectoryWriterLock(directory: directory)
    defer { _ = writerLock }
    try directory.makePrivate()
    let journal = try RestoreJournalStore(directory: directory, sourceID: plan.sourceID)
    try await journal.validate(plan.items)
    var report = RestoreReport()
    var verified: [RestoreItem] = []
    try await withThrowingTaskGroup(of: RestoreItemResult.self) { group in
        var cursor = 0
        func enqueue(_ item: RestoreItem) {
            group.addTask {
                do {
                    return try await restoreOne(
                        item, plan: plan, source: source, directory: directory, journal: journal,
                        archive: archive, archiveDeadline: archiveDeadline,
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return .failed(String(describing: error).prefix(240).description)
                }
            }
        }
        for _ in 0 ..< min(concurrency, plan.items.count) {
            enqueue(plan.items[cursor])
            cursor += 1
        }
        for try await result in group {
            switch result {
            case let .restored(item, size):
                report.restored += 1
                report.bytes += size
                verified.append(item)
            case let .skipped(item):
                report.skipped += 1
                verified.append(item)
            case .pending: report.pending += 1
            case let .failed(message):
                report.failed += 1
                if report.errors.count < 20 { report.errors.append(message) }
            }
            if cursor < plan.items.count { enqueue(plan.items[cursor])
                cursor += 1
            }
        }
    }
    if let photos, let importer {
        try await importRestoredPhotos(
            items: verified.sorted { $0.key < $1.key }, directory: directory, journal: journal,
            options: photos, importer: importer, report: &report,
        )
    }
    return report
}

private func restoreOne(
    _ item: RestoreItem,
    plan: RestorePlan,
    source: any ObjectDownloading,
    directory: SafeDirectory,
    journal: RestoreJournalStore,
    archive: RestoreArchiveOptions,
    archiveDeadline: Double,
) async throws -> RestoreItemResult {
    let size: Int64
    let result: RestoreItemResult
    if let existing = try directory.reader(key: item.relativePath) {
        defer { try? existing.close() }
        let digest = try SafeDirectory.digest(existing)
        try validateRestored(item, size: digest.size, checksum: digest.checksum)
        size = digest.size
        result = .skipped(item)
    } else {
        if let archived = source as? any ArchiveRetrieving {
            let readable = try await awaitReadableArchive(
                source: archived, key: item.key, options: archive, deadline: archiveDeadline,
            )
            if !readable { return .pending }
        }
        let downloaded = try await source.downloadObject(key: item.key)
        let input = try FileHandle(forReadingFrom: downloaded.fileURL)
        defer { try? input.close() }
        let digest = try SafeDirectory.digest(input)
        try validateRestored(item, size: digest.size, checksum: digest.checksum)
        try directory.copy(key: item.relativePath, fromFile: downloaded.fileURL, expectedSHA256: item.checksum)
        size = digest.size
        result = .restored(item, size)
    }
    try saveSidecar(item, sourceID: plan.sourceID, directory: directory)
    try await journal.completed(item, size: size)
    return result
}

private func saveSidecar(_ item: RestoreItem, sourceID: String, directory: SafeDirectory) throws {
    let key = "metadata/\(item.id).json"
    let existing = try directory.readIfPresent(key: key)
    if let existing {
        let old = try JSONDecoder().decode(RestoreSidecar.self, from: existing)
        guard old.schemaVersion == 1, old.sourceID == sourceID,
              old.original.key == item.key, old.original.checksum == item.checksum
        else { throw RestoreError.invalid("Refusing to overwrite unrelated recovery metadata") }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try directory.write(
        key: key, body: encoder.encode(RestoreSidecar(sourceID: sourceID, original: item)), replace: existing != nil,
    )
}

private func validateRestored(_ item: RestoreItem, size: Int64, checksum: String) throws {
    guard checksum == item.checksum, item.expectedSize == nil || size == item.expectedSize else {
        throw RestoreError
            .invalid("Original checksum or size verification failed; existing files are never overwritten")
    }
}
