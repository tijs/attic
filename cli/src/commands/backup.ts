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
import type { BackupLogger } from "../logger.ts";
import { createNullLogger } from "../logger.ts";
import { notify } from "../notify.ts";
import { withRetry } from "../retry.ts";

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
  /** Suppress progress output (for unattended/scripted use). */
  quiet: boolean;
  /** Structured JSONL logger (null logger if --log not given). */
  logger: BackupLogger;
  /** Send macOS notification on completion. */
  notifyOnComplete: boolean;
}

const DEFAULT_OPTIONS: BackupOptions = {
  batchSize: 50,
  limit: 0,
  type: null,
  dryRun: false,
  saveInterval: 50,
  quiet: false,
  logger: createNullLogger(),
  notifyOnComplete: false,
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
  const log = options.quiet ? () => {} : console.log.bind(console);
  const logger = options.logger;

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
    log("\n  Nothing to back up — all assets are current.\n");
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

  log(`\n  Attic — Backup`);
  log(`  ══════════════\n`);
  log(
    `  Pending:     ${pending.length.toLocaleString()} assets (${typeSummary})`,
  );
  log(`  Est. size:   ${formatBytes(pendingSize)}`);
  if (options.dryRun) log(`  Mode:        DRY RUN`);
  log();

  logger.start(pending.length, photoCount, videoCount);

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

  // AbortController for cancelling in-flight operations (subprocess, S3 uploads)
  const abortController = new AbortController();
  const { signal } = abortController;

  let interruptCount = 0;
  const onInterrupt = () => {
    interruptCount++;

    if (interruptCount === 1) {
      // First Ctrl+C: graceful — cancel in-flight operations, save manifest
      abortController.abort();
      manifestStore.save(manifest).catch(() => {});
    } else {
      // Second Ctrl+C: force exit. Manifest was last saved to S3
      // at most saveInterval assets ago. Any unsaved progress will
      // be re-uploaded on the next run (uploads are idempotent).
      console.error("\n  Force quit — progress saved up to last checkpoint.");
      Deno.exit(130);
    }
  };
  Deno.addSignalListener("SIGINT", onInterrupt);

  // Process in batches
  for (let i = 0; i < pending.length; i += options.batchSize) {
    if (signal.aborted) break;

    const batch = pending.slice(i, i + options.batchSize);
    const batchUuids = batch.map((a) => a.uuid);
    const batchNum = Math.floor(i / options.batchSize) + 1;
    const totalBatches = Math.ceil(pending.length / options.batchSize);

    if (totalBatches > 1) {
      log(`  Batch ${batchNum}/${totalBatches}  (${batch.length} assets)`);
    }

    // 1. Export via ladder
    const spinner = options.quiet
      ? { stop() {} }
      : startSpinner(`Exporting ${batch.length} assets from Photos library...`);
    let batchResult;
    try {
      batchResult = await exporter.exportBatch(batchUuids, signal);
    } catch (error: unknown) {
      spinner.stop();
      if (signal.aborted) break;
      const msg = error instanceof Error ? error.message : String(error);
      console.error(`    Export failed: ${msg}`);
      for (const uuid of batchUuids) {
        report.errors.push({ uuid, message: msg });
        report.failed++;
        logger.error(uuid, msg);
      }
      continue;
    }
    spinner.stop();

    // Record export errors
    for (const err of batchResult.errors) {
      console.error(`    Export error: ${err.uuid} — ${err.message}`);
      report.errors.push(err);
      report.failed++;
      logger.error(err.uuid, err.message);
    }

    // 2. Upload each exported file to S3
    for (const exported of batchResult.results) {
      if (signal.aborted) break;
      const asset = assetByUuid.get(exported.uuid);
      if (!asset) continue;

      const ext = extensionFromUtiOrFilename(
        asset.uniformTypeIdentifier,
        asset.originalFilename ?? asset.filename,
      );
      const s3Key = originalKey(asset.uuid, asset.dateCreated, ext);

      try {
        // Read file and upload to S3 (with retry for transient failures)
        let fileData: Uint8Array | null = await Deno.readFile(exported.path);
        await withRetry(
          () => s3.putObject(s3Key, fileData!, contentTypeFor(ext)),
          { signal },
        );
        fileData = null; // Allow GC before metadata upload

        // Upload metadata JSON (with retry)
        const meta = buildMetadataJson(
          asset,
          s3Key,
          `sha256:${exported.sha256}`,
          new Date().toISOString(),
        );
        const metaData = new TextEncoder().encode(
          JSON.stringify(meta, null, 2),
        );
        await withRetry(
          () =>
            s3.putObject(
              metadataKey(asset.uuid),
              metaData,
              "application/json",
            ),
          { signal },
        );

        // Update manifest
        markBackedUp(
          manifest,
          asset.uuid,
          `sha256:${exported.sha256}`,
          s3Key,
          exported.size,
        );
        sinceLastSave++;
        report.uploaded++;
        report.totalBytes += exported.size;

        const name = asset.originalFilename ?? asset.filename ?? "unknown";
        const typeLabel = asset.kind === AssetKind.PHOTO ? "photo" : "video";
        logger.uploaded(asset.uuid, name, typeLabel, exported.size);

        // Per-asset progress
        if (!options.quiet) {
          const done = report.uploaded + report.failed;
          const pct = ((done / pending.length) * 100).toFixed(0);
          log(
            `  [${done}/${pending.length}] ${pct}%  ${name}  (${typeLabel}, ${
              formatBytes(exported.size)
            })`,
          );
        }

        // Save manifest periodically (checked per-asset, not per-batch)
        if (sinceLastSave >= options.saveInterval) {
          await manifestStore.save(manifest);
          sinceLastSave = 0;
        }
      } catch (error: unknown) {
        if (signal.aborted) break;
        const msg = error instanceof Error ? error.message : String(error);
        console.error(`    Upload error: ${exported.uuid} — ${msg}`);
        report.errors.push({ uuid: exported.uuid, message: msg });
        report.failed++;
        logger.error(exported.uuid, msg);
      } finally {
        // Always clean up staged file, even on interruption or error
        await removeStagedFile(exported.path, resolvedStagingDir);
      }
    }

    // Batch separator when multiple batches
    if (totalBatches > 1 && batchNum < totalBatches) {
      log();
    }
  }

  // Final save
  if (sinceLastSave > 0) {
    await manifestStore.save(manifest);
  }

  // Summary
  Deno.removeSignalListener("SIGINT", onInterrupt);

  if (signal.aborted) {
    log(`\n\n  ── Interrupted ──`);
    log(
      `  Uploaded:  ${report.uploaded.toLocaleString()} of ${pending.length.toLocaleString()}`,
    );
    log(`  Total:     ${formatBytes(report.totalBytes)}`);
    log(`  Manifest saved — will resume from here next run.\n`);
    logger.interrupted(report.uploaded, pending.length, report.totalBytes);
  } else {
    log(`\n  ── Complete ──`);
    log(`  Uploaded:  ${report.uploaded.toLocaleString()}`);
    log(`  Failed:    ${report.failed.toLocaleString()}`);
    log(`  Total:     ${formatBytes(report.totalBytes)}`);
    if (report.failed > 0) {
      log(`\n  Run \`attic backup\` again to retry failed assets.`);
    }
    log();
    logger.complete(report.uploaded, report.failed, report.totalBytes);
  }

  // macOS notification
  if (options.notifyOnComplete) {
    if (report.failed > 0) {
      await notify(
        "Attic Backup",
        `Done with errors: ${report.uploaded} uploaded, ${report.failed} failed`,
        "Basso",
      );
    } else if (signal.aborted) {
      await notify(
        "Attic Backup",
        `Interrupted: ${report.uploaded} of ${pending.length} uploaded`,
        "Basso",
      );
    } else {
      await notify(
        "Attic Backup",
        `Complete: ${report.uploaded} assets (${
          formatBytes(report.totalBytes)
        })`,
      );
    }
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
