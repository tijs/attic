import Foundation
import LadderKit

/// Result of uploading a single asset, returned from TaskGroup child tasks.
struct UploadResult {
    let uuid: String
    let s3Key: String
    let checksum: String?
    let filename: String
    let type: AssetKind
    let size: Int
    let error: String?
    let isNetworkDownError: Bool
    let path: String
}

/// Inputs for a single concurrent upload task.
struct UploadInput {
    let exported: ExportResult
    let asset: AssetInfo
    let s3Key: String
    let ext: String
}

/// Upload a single asset (original + metadata) to S3. Returns an UploadResult.
///
/// This is a pure `@Sendable` function — no mutation of shared state.
/// Manifest updates happen in the caller's `for await` loop.
func uploadSingleAsset(
    input: UploadInput,
    s3: any S3Providing,
) async -> UploadResult {
    let exported = input.exported
    let asset = input.asset
    let s3Key = input.s3Key
    let ext = input.ext

    do {
        // Upload original via file URL (avoids loading into memory)
        let fileURL = URL(fileURLWithPath: exported.path)
        try await withRetry {
            try await s3.putObject(
                key: s3Key,
                fileURL: fileURL,
                contentType: contentTypeForExtension(ext),
            )
        }

        // Build and upload metadata (per-call formatter for thread safety)
        let formatter = ISO8601DateFormatter()
        let isoNow = formatter.string(from: Date())
        let meta = buildMetadataJSON(
            asset: asset,
            s3Key: s3Key,
            checksum: "sha256:\(exported.sha256)",
            backedUpAt: isoNow,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metaData = try encoder.encode(meta)
        let metaKey = try S3Paths.metadataKey(uuid: asset.uuid)
        try await withRetry {
            try await s3.putObject(
                key: metaKey,
                body: metaData,
                contentType: "application/json",
            )
        }

        return UploadResult(
            uuid: asset.uuid,
            s3Key: s3Key,
            checksum: "sha256:\(exported.sha256)",
            filename: asset.originalFilename ?? "unknown",
            type: asset.kind,
            size: Int(exported.size),
            error: nil,
            isNetworkDownError: false,
            path: exported.path,
        )
    } catch {
        return UploadResult(
            uuid: asset.uuid,
            s3Key: s3Key,
            checksum: nil,
            filename: asset.originalFilename ?? "unknown",
            type: asset.kind,
            size: Int(exported.size),
            error: String(describing: error),
            isNetworkDownError: isNetworkDown(error),
            path: exported.path,
        )
    }
}
