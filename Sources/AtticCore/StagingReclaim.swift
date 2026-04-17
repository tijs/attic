import Foundation
import LadderKit

/// Result of scanning the staging directory for previously-exported files.
public struct ReclaimResult: Sendable {
    /// Export results built from files already on disk (SHA-256 recomputed).
    public var reclaimed: [ExportResult]
    /// UUIDs that have no staged file and still need fresh export.
    public var remaining: [String]
}

/// Scan `stagingDir` for files matching `uuids` from a previous export.
///
/// For each UUID, checks if a file whose name starts with `{sanitizedUUID}_` exists.
/// If found, recomputes SHA-256 and builds an `ExportResult`. If multiple files match
/// a single UUID (e.g. PhotoKit + AppleScript variants), keeps the first and deletes
/// the rest.
///
/// Returns reclaimed results and the UUIDs that still need fresh export.
public func reclaimStagedFiles(
    uuids: [String],
    stagingDir: URL,
) -> ReclaimResult {
    let contents: [URL]
    do {
        contents = try FileManager.default.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.fileSizeKey],
        )
    } catch {
        // Can't read staging dir — everything needs fresh export
        return ReclaimResult(reclaimed: [], remaining: uuids)
    }

    // Pre-compute sanitized prefixes to avoid redundant work in the inner loop
    var prefixToUUID: [String: String] = [:]
    for uuid in uuids {
        prefixToUUID[PathSafety.sanitizeFilename(uuid) + "_"] = uuid
    }

    // Build a filename lookup: files grouped by their UUID prefix
    var filesByUUID: [String: [URL]] = [:]
    for url in contents {
        let name = url.lastPathComponent
        for (prefix, uuid) in prefixToUUID {
            if name.hasPrefix(prefix) {
                filesByUUID[uuid, default: []].append(url)
                break
            }
        }
    }

    var reclaimed: [ExportResult] = []
    var remaining: [String] = []

    for uuid in uuids {
        guard var matches = filesByUUID[uuid], !matches.isEmpty else {
            remaining.append(uuid)
            continue
        }

        let kept = matches.removeFirst()

        // Delete duplicates (e.g. PhotoKit + AppleScript variants)
        for extra in matches {
            try? FileManager.default.removeItem(at: extra)
        }

        // Recompute SHA-256 to guarantee integrity
        do {
            let sha256 = try FileHasher.sha256(fileAt: kept)
            let attrs = try FileManager.default.attributesOfItem(atPath: kept.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

            reclaimed.append(ExportResult(
                uuid: uuid,
                path: kept.path,
                size: size,
                sha256: sha256,
            ))
        } catch {
            // File is corrupt or unreadable — delete it and re-export
            try? FileManager.default.removeItem(at: kept)
            remaining.append(uuid)
        }
    }

    return ReclaimResult(reclaimed: reclaimed, remaining: remaining)
}
