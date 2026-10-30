import Foundation

struct RestoreJournalRecord: Codable, Sendable {
    let key: String
    let checksum: String
    let size: Int64
    var importState: String?
    var importedIDs: [String]?
    var importLibrary: String?
}

private struct RestoreJournal: Codable {
    var version = 1
    let sourceID: String
    var records: [String: RestoreJournalRecord] = [:]
}

actor RestoreJournalStore {
    private let directory: SafeDirectory
    private var journal: RestoreJournal
    private static let key = ".attic-restore.json"

    init(directory: SafeDirectory, sourceID: String) throws {
        self.directory = directory
        if let data = try directory.readIfPresent(key: Self.key) {
            let loaded = try JSONDecoder().decode(RestoreJournal.self, from: data)
            guard loaded.version == 1, loaded.sourceID == sourceID else {
                throw RestoreError
                    .invalid("Restore journal belongs to another backup or schema; select a new destination")
            }
            for (id, record) in loaded.records {
                try RestoreValidation.objectKey(record.key)
                guard record.key.hasPrefix("originals/"), record.checksum.count == 64, record.size >= 0,
                      id == RestoreItem.identifier(record.key),
                      record.importState == nil || ["pending", "imported", "failed", "uncertain"]
                          .contains(record.importState!)
                else { throw RestoreError.invalid("Invalid restore journal record") }
                _ = try RestoreValidation.checksum("sha256:" + record.checksum)
                if record.importState != nil {
                    guard let library = record.importLibrary, !library.isEmpty, library.count <= 512 else {
                        throw RestoreError.invalid("Import journal has no library identity")
                    }
                    if record.importState == "imported", record.importedIDs == nil {
                        throw RestoreError.invalid("Import journal has no recorded identifiers")
                    }
                    if let ids = record.importedIDs {
                        guard ids.count <= 100, ids.allSatisfy({ S3Paths.isValidUUID($0) && $0.count <= 512 }) else {
                            throw RestoreError.invalid("Invalid imported identifiers in restore journal")
                        }
                    }
                }
            }
            journal = loaded
        } else {
            journal = RestoreJournal(sourceID: sourceID)
            try directory.write(key: Self.key, body: Self.encode(journal), replace: false)
        }
    }

    func validate(_ items: [RestoreItem]) throws {
        for item in items {
            if let record = journal.records[item.id] {
                guard record.key == item.key, record.checksum == item.checksum,
                      item.expectedSize == nil || item.expectedSize == record.size
                else { throw RestoreError.invalid("Backup changed since this restore journal was created") }
            }
        }
    }

    func record(for item: RestoreItem) -> RestoreJournalRecord? { journal.records[item.id] }

    func completed(_ item: RestoreItem, size: Int64) throws {
        if let existing = journal.records[item.id] {
            guard existing.checksum == item.checksum, existing.size == size else {
                throw RestoreError.invalid("Restore journal checksum or size disagrees")
            }
        } else {
            journal.records[item.id] = RestoreJournalRecord(key: item.key, checksum: item.checksum, size: size)
        }
        try save()
    }

    func importOutcome(_ item: RestoreItem, library: String, state: String, ids: [String]? = nil) throws {
        guard var record = journal.records[item.id] else { throw RestoreError.invalid("Original is not verified") }
        record.importState = state
        record.importLibrary = library
        record.importedIDs = ids
        journal.records[item.id] = record
        try save()
    }

    private func save() throws {
        try directory.write(key: Self.key, body: Self.encode(journal), replace: true)
    }

    private static func encode(_ journal: RestoreJournal) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(journal)
    }
}
