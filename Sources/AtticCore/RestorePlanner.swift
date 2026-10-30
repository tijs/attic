import Foundation
import UniformTypeIdentifiers

private struct RestoreCandidate: Sendable {
    let entry: ManifestEntry
    let metadata: AssetMetadata?
    let warning: Bool
    let selected: Bool
}

/// Plan recovery without mutating storage, consulting Photos, or migrating identity.
public func planRestore(
    manifest: Manifest,
    source: any ObjectProviding,
    sourceID: String,
    filters: RestoreFilters = RestoreFilters(),
    concurrency: Int = 8,
) async throws -> RestorePlan {
    guard !sourceID.isEmpty, sourceID.count <= 512, (1 ... 2).contains(manifest.version),
          (1 ... 32).contains(concurrency),
          filters.type == nil || ["photo", "video"].contains(filters.type!),
          filters.from == nil || filters.before == nil || filters.from! < filters.before!
    else { throw RestoreError.invalid("Unsupported manifest version, filter, or restore concurrency") }
    let entries = manifest.entries.values.sorted { $0.uuid < $1.uuid }
    var byKey: [String: ManifestEntry] = [:]
    for (uuid, entry) in manifest.entries {
        guard uuid == entry.uuid, S3Paths.isValidUUID(uuid), entry.s3Key.hasPrefix("originals/"),
              entry.size == nil || entry.size! >= 0
        else { throw RestoreError.invalid("Invalid original identity or size in manifest") }
        try RestoreValidation.objectKey(entry.s3Key)
        _ = try RestoreValidation.checksum(entry.checksum)
        if let prior = byKey[entry.s3Key] {
            guard try RestoreValidation.checksum(prior.checksum) == RestoreValidation.checksum(entry.checksum),
                  prior.size == nil || entry.size == nil || prior.size == entry.size
            else { throw RestoreError.invalid("Conflicting records for the same original object") }
        }
        byKey[entry.s3Key] = entry
    }
    var candidates: [RestoreCandidate] = []
    try await withThrowingTaskGroup(of: RestoreCandidate.self) { group in
        var cursor = 0
        func enqueue(_ entry: ManifestEntry) {
            group.addTask { try await inspectCandidate(entry, source: source, filters: filters) }
        }
        for _ in 0 ..< min(concurrency, entries.count) {
            enqueue(entries[cursor])
            cursor += 1
        }
        for try await candidate in group {
            candidates.append(candidate)
            if cursor < entries.count { enqueue(entries[cursor])
                cursor += 1
            }
        }
    }
    let groups = Dictionary(grouping: candidates.filter(\.selected), by: { $0.entry.s3Key })
    let items = try groups.keys.sorted().map { key in
        let matches = groups[key]!.sorted { $0.entry.uuid < $1.entry.uuid }
        let entry = matches[0].entry
        return try RestoreItem(
            key: key, checksum: RestoreValidation.checksum(entry.checksum),
            expectedSize: matches.compactMap { $0.entry.size ?? $0.metadata?.fileSize }.first.map(Int64.init),
            uuids: matches.map(\.entry.uuid), metadata: matches.compactMap(\.metadata),
            metadataWarnings: matches.filter(\.warning).count,
        )
    }
    return RestorePlan(sourceID: sourceID, items: items)
}

private func inspectCandidate(
    _ entry: ManifestEntry,
    source: any ObjectProviding,
    filters: RestoreFilters,
) async throws -> RestoreCandidate {
    let metadata: AssetMetadata
    let raw: [String: Any]
    do {
        let data = try await source.getObject(key: S3Paths.metadataKey(uuid: entry.uuid))
        raw = try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        metadata = try JSONDecoder().decode(AssetMetadata.self, from: data)
        guard metadata.uuid == entry.uuid, metadata.s3Key == entry.s3Key,
              try RestoreValidation.checksum(metadata.checksum) == RestoreValidation.checksum(entry.checksum),
              metadata.fileSize == nil || metadata.fileSize! >= 0,
              entry.size == nil || metadata.fileSize == nil || entry.size == metadata.fileSize
        else { throw RestoreError.invalid("Metadata does not match its manifest entry") }
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        if filters.requiresMetadata {
            throw RestoreError
                .invalid("A metadata filter cannot be evaluated: metadata is missing, unreadable, or inconsistent")
        }
        return RestoreCandidate(entry: entry, metadata: nil, warning: true, selected: true)
    }
    let selected = try matchesFilters(metadata, hasAlbums: raw["albums"] is [[String: Any]], filters: filters)
    return RestoreCandidate(entry: entry, metadata: metadata, warning: false, selected: selected)
}

private func matchesFilters(_ metadata: AssetMetadata, hasAlbums: Bool, filters: RestoreFilters) throws -> Bool {
    var selected = true
    if filters.from != nil || filters.before != nil {
        guard let raw = metadata.dateCreated, let date = restoreCreationDate(raw) else {
            throw RestoreError.invalid("Date filtering requires a valid creation date for every candidate")
        }
        if let from = filters.from, date < from { selected = false }
        if let before = filters.before, date >= before { selected = false }
    }
    if let type = filters.type {
        guard let raw = metadata.type, let uti = UTType(raw),
              uti.conforms(to: .image) || uti.conforms(to: .movie)
        else {
            throw RestoreError.invalid("Type filtering requires a known image/video type for every candidate")
        }
        if type == "photo" ? !uti.conforms(to: .image) : !uti.conforms(to: .movie) { selected = false }
    }
    if let album = filters.album {
        guard hasAlbums else { throw RestoreError.invalid("Album filtering requires an explicit album list") }
        if !metadata.albums.contains(where: { $0.uuid == album }) { selected = false }
    }
    return selected
}

private func restoreCreationDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}
