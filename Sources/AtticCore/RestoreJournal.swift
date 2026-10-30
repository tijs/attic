import Foundation

struct RestoreJournalRecord: Codable, Sendable, Equatable {
    let key: String
    let checksum: String
    let size: Int64
    var importState: String?
    var importedIDs: [String]?
    var importLibrary: String?
}

private struct RestoreJournal: Codable {
    var version = 2
    let sourceID: String
    /// Retain v1 snapshot records during a one-time upgrade. Per-resource files
    /// override these records; the snapshot is never rewritten per completion.
    var records: [String: RestoreJournalRecord] = [:]
}

private struct RestoreJournalRecordFile: Codable {
    var version = 1
    let sourceID: String
    let record: RestoreJournalRecord
}

actor RestoreJournalStore {
    private let directory: SafeDirectory
    private let sourceID: String
    private var records: [String: RestoreJournalRecord]
    private var loadedIDs: Set<String> = []
    private static let key = ".attic-restore.json"

    init(directory: SafeDirectory, sourceID: String) throws {
        self.directory = directory
        self.sourceID = sourceID
        if let data = try directory.readIfPresent(key: Self.key) {
            var loaded = try JSONDecoder().decode(RestoreJournal.self, from: data)
            guard [1, 2].contains(loaded.version), loaded.sourceID == sourceID else {
                throw RestoreError
                    .invalid("Restore journal belongs to another backup or schema; select a new destination")
            }
            for (id, record) in loaded.records {
                try Self.validateRecord(record, id: id)
            }
            if loaded.version == 1 {
                // Publish the version gate before creating incremental records so
                // an older binary cannot ignore durable Photos import intent.
                loaded.version = 2
                try directory.write(key: Self.key, body: Self.encode(loaded), replace: true)
            }
            records = loaded.records
        } else {
            let journal = RestoreJournal(sourceID: sourceID)
            try directory.write(key: Self.key, body: Self.encode(journal), replace: false)
            records = [:]
        }
    }

    func validate(_ items: [RestoreItem]) throws {
        for item in items {
            _ = try record(for: item)
        }
    }

    func record(for item: RestoreItem) throws -> RestoreJournalRecord? {
        if !loadedIDs.contains(item.id) {
            if let data = try directory.readIfPresent(key: Self.recordKey(item.id)) {
                let loaded = try JSONDecoder().decode(RestoreJournalRecordFile.self, from: data)
                guard loaded.version == 1, loaded.sourceID == sourceID else {
                    throw RestoreError.invalid("Recovery record belongs to another backup or schema")
                }
                try Self.validateRecord(loaded.record, id: item.id)
                records[item.id] = loaded.record
            }
            loadedIDs.insert(item.id)
        }
        guard let record = records[item.id] else { return nil }
        guard record.key == item.key, record.checksum == item.checksum,
              item.expectedSize == nil || item.expectedSize == record.size
        else { throw RestoreError.invalid("Backup changed since this restore journal was created") }
        return record
    }

    func completed(_ item: RestoreItem, size: Int64) throws {
        if let existing = try record(for: item) {
            guard existing.size == size else { throw RestoreError.invalid("Restore journal size disagrees") }
            return
        }
        try save(RestoreJournalRecord(key: item.key, checksum: item.checksum, size: size), id: item.id)
    }

    func importOutcome(_ item: RestoreItem, library: String, state: String, ids: [String]? = nil) throws {
        guard let existing = try record(for: item) else { throw RestoreError.invalid("Original is not verified") }
        var updated = existing
        updated.importState = state
        updated.importLibrary = library
        updated.importedIDs = ids
        guard updated != existing else { return }
        try save(updated, id: item.id)
    }

    private func save(_ record: RestoreJournalRecord, id: String) throws {
        try Self.validateRecord(record, id: id)
        let file = RestoreJournalRecordFile(sourceID: sourceID, record: record)
        try directory.write(key: Self.recordKey(id), body: Self.encode(file), replace: true)
        // A failed publication must not appear durable to later calls on this actor.
        records[id] = record
        loadedIDs.insert(id)
    }

    private static func recordKey(_ id: String) -> String { ".attic-restore-records/\(id).json" }

    private static func validateRecord(_ record: RestoreJournalRecord, id: String) throws {
        try RestoreValidation.objectKey(record.key)
        guard record.key.hasPrefix("originals/"), record.checksum.count == 64, record.size >= 0,
              id == RestoreItem.identifier(record.key),
              record.importState == nil || ["pending", "imported", "failed", "uncertain"].contains(record.importState!)
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

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(value)
    }
}
