import type { PhotoAsset } from "@attic/shared";
import {
  AssetKind,
  buildMetadataJson,
  extensionFromUtiOrFilename,
  metadataKey,
  originalKey,
} from "@attic/shared";
import type { Manifest, ManifestStore } from "../manifest/manifest.ts";
import { isBackedUp, markBackedUp } from "../manifest/manifest.ts";
import type { Exporter } from "../export/exporter.ts";
import { removeStagedFile } from "../export/exporter.ts";
import type { S3Provider } from "../storage/s3-client.ts";
import { formatBytes } from "../format.ts";
import { startSpinner } from "../spinner.ts";

export interface BackupOptions {
  /** Maximum assets per ladder batch. */
  batchSize: number;
  /** Stop after this many assets total (0 = unlimited). */
  limit: number;
  /** Only process assets of this type (null = all). */
  type: "photo" | "video" | null;
  /** Skip uploads, just show what would happen. */
  dryRun: boolean;
  /** Save manifest every N assets. */
  saveInterval: number;
}

const DEFAULT_OPTIONS: BackupOptions = {
  batchSize: 50,
  limit: 0,
  type: null,
  dryRun: false,
  saveInterval: 50,
};

export interface BackupReport {
  uploaded: number;
  failed: number;
  skipped: number;
  totalBytes: number;
  errors: Array<{ uuid: string; message: string }>;
}

/** Run the backup pipeline: scan -> filter -> export -> upload -> manifest. */
export async function runBackup(
  assets: PhotoAsset[],
  manifest: Manifest,
  manifestStore: ManifestStore,
  exporter: Exporter,
  s3: S3Provider,
  opts: Partial<BackupOptions> = {},
  stagingDir?: string,
): Promise<BackupReport> {
  const options = { ...DEFAULT_OPTIONS, ...opts };

  // Filter to pending assets
  let pending = assets.filter((a) => !isBackedUp(manifest, a.uuid));

  // Filter by type if requested
  if (options.type === "photo") {
    pending = pending.filter((a) => a.kind === AssetKind.PHOTO);
  } else if (options.type === "video") {
    pending = pending.filter((a) => a.kind === AssetKind.VIDEO);
  }

  // Apply limit
  if (options.limit > 0) {
    pending = pending.slice(0, options.limit);
  }

  if (pending.length === 0) {
    console.log("\n  Nothing to back up — all assets are current.\n");
    return { uploaded: 0, failed: 0, skipped: 0, totalBytes: 0, errors: [] };
  }

  const pendingSize = pending.reduce(
    (sum, a) => sum + (a.originalFileSize ?? 0),
    0,
  );

  const photoCount = pending.filter((a) => a.kind === AssetKind.PHOTO).length;
  const videoCount = pending.filter((a) => a.kind === AssetKind.VIDEO).length;
  const typeSummary = [
    photoCount > 0 ? `${photoCount} photos` : "",
    videoCount > 0 ? `${videoCount} videos` : "",
  ].filter(Boolean).join(", ");

  console.log(`\n  Attic — Backup`);
  console.log(`  ══════════════\n`);
  console.log(`  Pending:     ${pending.length.toLocaleString()} assets (${typeSummary})`);
  console.log(`  Est. size:   ${formatBytes(pendingSize)}`);
  if (options.dryRun) console.log(`  Mode:        DRY RUN`);
  console.log();

  if (options.dryRun) {
    return {
      uploaded: 0,
      failed: 0,
      skipped: pending.length,
      totalBytes: 0,
      errors: [],
    };
  }

  // Build UUID-to-asset lookup for metadata
  const assetByUuid = new Map<string, PhotoAsset>();
  for (const a of pending) {
    assetByUuid.set(a.uuid, a);
  }

  // Resolve staging directory for safe file cleanup
  const resolvedStagingDir = stagingDir ??
    (exporter as { stagingDir?: string }).stagingDir ??
    `${Deno.env.get("HOME") ?? "~"}/.attic/staging`;

  const report: BackupReport = {
    uploaded: 0,
    failed: 0,
    skipped: 0,
    totalBytes: 0,
    errors: [],
  };

  let sinceLastSave = 0;
  let interrupted = false;

  // Save manifest on SIGINT (Ctrl+C) before exiting
  const onInterrupt = () => { interrupted = true; };
  Deno.addSignalListener("SIGINT", onInterrupt);

  // Process in batches
  for (let i = 0; i < pending.length; i += options.batchSize) {
    if (interrupted) break;

    const batch = pending.slice(i, i + options.batchSize);
    const batchUuids = batch.map((a) => a.uuid);
    const batchNum = Math.floor(i / options.batchSize) + 1;
    const totalBatches = Math.ceil(pending.length / options.batchSize);

    if (totalBatches > 1) {
      console.log(
        `  Batch ${batchNum}/${totalBatches}  (${batch.length} assets)`,
      );
    }

    // 1. Export via ladder
    const spinner = startSpinner(
      `Exporting ${batch.length} assets from Photos library...`,
    );
    let batchResult;
    try {
      batchResult = await exporter.exportBatch(batchUuids);
    } catch (error: unknown) {
      spinner.stop();
      const msg = error instanceof Error
        ? error.message
        : "Unknown export error";
      console.error(`    Export failed: ${msg}`);
      for (const uuid of batchUuids) {
        report.errors.push({ uuid, message: msg });
        report.failed++;
      }
      continue;
    }
    spinner.stop();

    // Record export errors
    for (const err of batchResult.errors) {
      console.error(`    Export error: ${err.uuid} — ${err.message}`);
      report.errors.push(err);
      report.failed++;
    }

    // 2. Upload each exported file to S3
    for (const exported of batchResult.results) {
      if (interrupted) break;
      const asset = assetByUuid.get(exported.uuid);
      if (!asset) continue;

      const ext = extensionFromUtiOrFilename(
        asset.uniformTypeIdentifier,
        asset.originalFilename ?? asset.filename,
      );
      const s3Key = originalKey(asset.uuid, asset.dateCreated, ext);

      try {
        // Read file and upload to S3
        const fileData = await Deno.readFile(exported.path);
        await s3.putObject(s3Key, fileData, contentTypeFor(ext));

        // Upload metadata JSON
        const meta = buildMetadataJson(
          asset,
          s3Key,
          `sha256:${exported.sha256}`,
          new Date().toISOString(),
        );
        const metaData = new TextEncoder().encode(
          JSON.stringify(meta, null, 2),
        );
        await s3.putObject(
          metadataKey(asset.uuid),
          metaData,
          "application/json",
        );

        // Update manifest
        markBackedUp(manifest, asset.uuid, `sha256:${exported.sha256}`, s3Key);
        sinceLastSave++;
        report.uploaded++;
        report.totalBytes += exported.size;

        // Per-asset progress
        const done = report.uploaded + report.failed;
        const pct = ((done / pending.length) * 100).toFixed(0);
        const name = asset.originalFilename ?? asset.filename ?? "unknown";
        const typeLabel = asset.kind === AssetKind.PHOTO ? "photo" : "video";
        console.log(
          `  [${done}/${pending.length}] ${pct}%  ${name}  (${typeLabel}, ${formatBytes(exported.size)})`,
        );

        // Save manifest periodically (checked per-asset, not per-batch)
        if (sinceLastSave >= options.saveInterval) {
          await manifestStore.save(manifest);
          sinceLastSave = 0;
        }

        // Clean up staged file
        await removeStagedFile(exported.path, resolvedStagingDir);
      } catch (error: unknown) {
        const msg = error instanceof Error
          ? error.message
          : "Unknown upload error";
        console.error(`    Upload error: ${exported.uuid} — ${msg}`);
        report.errors.push({ uuid: exported.uuid, message: msg });
        report.failed++;
        // Still try to clean up staged file
        await removeStagedFile(exported.path, resolvedStagingDir);
      }
    }

    // Batch separator when multiple batches
    if (totalBatches > 1 && batchNum < totalBatches) {
      console.log();
    }
  }

  // Final save
  if (sinceLastSave > 0) {
    await manifestStore.save(manifest);
  }

  // Summary
  Deno.removeSignalListener("SIGINT", onInterrupt);

  if (interrupted) {
    console.log(`\n\n  ── Interrupted ──`);
    console.log(`  Uploaded:  ${report.uploaded.toLocaleString()} of ${pending.length.toLocaleString()}`);
    console.log(`  Total:     ${formatBytes(report.totalBytes)}`);
    console.log(`  Manifest saved — will resume from here next run.\n`);
  } else {
    console.log(`\n  ── Complete ──`);
    console.log(`  Uploaded:  ${report.uploaded.toLocaleString()}`);
    console.log(`  Failed:    ${report.failed.toLocaleString()}`);
    console.log(`  Total:     ${formatBytes(report.totalBytes)}\n`);
  }

  return report;
}

function contentTypeFor(ext: string): string {
  const map: Record<string, string> = {
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    heic: "image/heic",
    png: "image/png",
    tiff: "image/tiff",
    gif: "image/gif",
    mp4: "video/mp4",
    mov: "video/quicktime",
    m4v: "video/x-m4v",
    avi: "video/x-msvideo",
    orf: "image/x-olympus-orf",
  };
  return map[ext] ?? "application/octet-stream";
}
