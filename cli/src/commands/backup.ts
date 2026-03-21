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
import type { ExportBatchResult, Exporter } from "../export/exporter.ts";
import { isTimeoutError, removeStagedFile } from "../export/exporter.ts";
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

  // Apply limit (preserves natural DB order for asset selection)
  if (options.limit > 0) {
    pending = pending.slice(0, options.limit);
  }

  // Sort: photos first, then videos; within each group by size ascending.
  // This keeps fast-to-export photos together and large videos at the end.
  pending.sort((a, b) => {
    if (a.kind !== b.kind) return a.kind - b.kind; // PHOTO=0 before VIDEO=1
    return (a.originalFileSize ?? 0) - (b.originalFileSize ?? 0);
  });

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

  // Helper: format asset name for log messages
  function assetLabel(uuid: string): string {
    const a = assetByUuid.get(uuid);
    if (!a) return uuid.substring(0, 8);
    const name = a.originalFilename ?? a.filename ?? uuid.substring(0, 8);
    const size = a.originalFileSize ? formatBytes(a.originalFileSize) : "?";
    const type = a.kind === AssetKind.PHOTO ? "photo" : "video";
    return `${name} (${type}, ${size})`;
  }

  // Helper: upload exported assets to S3, update manifest and report
  async function uploadExported(
    batchResult: ExportBatchResult,
  ): Promise<void> {
    // Record export errors
    for (const err of batchResult.errors) {
      console.error(`    Export error: ${err.uuid} — ${err.message}`);
      report.errors.push(err);
      report.failed++;
      logger.error(err.uuid, err.message);
    }

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
        let fileData: Uint8Array | null = await Deno.readFile(exported.path);
        await withRetry(
          () => s3.putObject(s3Key, fileData!, contentTypeFor(ext)),
          { signal },
        );
        fileData = null;

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

        if (!options.quiet) {
          const done = report.uploaded + report.failed;
          const pct = ((done / pending.length) * 100).toFixed(0);
          log(
            `  [${done}/${pending.length}] ${pct}%  ${name}  (${typeLabel}, ${
              formatBytes(exported.size)
            })`,
          );
        }

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
        await removeStagedFile(exported.path, resolvedStagingDir);
      }
    }
  }

  // Assets deferred due to individual timeout — retried after all batches
  const deferred: string[] = [];

  // Process in batches
  for (let i = 0; i < pending.length; i += options.batchSize) {
    if (signal.aborted) break;

    const batch = pending.slice(i, i + options.batchSize);
    const batchUuids = batch.map((a) => a.uuid);
    const batchNum = Math.floor(i / options.batchSize) + 1;
    const totalBatches = Math.ceil(pending.length / options.batchSize);

    const batchPhotos = batch.filter((a) => a.kind === AssetKind.PHOTO).length;
    const batchVideos = batch.length - batchPhotos;
    const batchBytes = batch.reduce(
      (sum, a) => sum + (a.originalFileSize ?? 0),
      0,
    );

    if (totalBatches > 1) {
      const parts = [
        batchPhotos > 0 ? `${batchPhotos} photos` : "",
        batchVideos > 0 ? `${batchVideos} videos` : "",
      ].filter(Boolean).join(", ");
      log(
        `  Batch ${batchNum}/${totalBatches}  (${parts}, ~${
          formatBytes(batchBytes)
        })`,
      );
    }

    exporter.setEstimatedBatchBytes?.(batchBytes);

    // 1. Export via ladder
    const spinner = options.quiet
      ? { stop() {} }
      : startSpinner(`Exporting ${batch.length} assets from Photos library...`);
    let batchResult: ExportBatchResult;
    try {
      batchResult = await exporter.exportBatch(batchUuids, signal);
    } catch (error: unknown) {
      spinner.stop();
      if (signal.aborted) break;

      // On timeout: retry each asset individually to find the slow ones
      if (isTimeoutError(error)) {
        log(
          `    Batch timed out — retrying ${batch.length} assets individually...`,
        );
        const combined: ExportBatchResult = { results: [], errors: [] };

        for (const uuid of batchUuids) {
          if (signal.aborted) break;
          const assetBytes = assetByUuid.get(uuid)?.originalFileSize ?? 0;
          exporter.setEstimatedBatchBytes?.(assetBytes);
          try {
            const result = await exporter.exportBatch([uuid], signal);
            combined.results.push(...result.results);
            combined.errors.push(...result.errors);
          } catch (innerError: unknown) {
            if (signal.aborted) break;
            if (isTimeoutError(innerError)) {
              log(
                `    Deferring ${
                  assetLabel(uuid)
                } — timed out, will retry after remaining batches`,
              );
              deferred.push(uuid);
            } else {
              const msg = innerError instanceof Error
                ? innerError.message
                : String(innerError);
              report.errors.push({ uuid, message: msg });
              report.failed++;
              logger.error(uuid, msg);
            }
          }
        }

        // Upload whatever succeeded from individual retries
        await uploadExported(combined);
      } else {
        // Non-timeout error: fail the whole batch
        const msg = error instanceof Error ? error.message : String(error);
        console.error(`    Export failed: ${msg}`);
        for (const uuid of batchUuids) {
          report.errors.push({ uuid, message: msg });
          report.failed++;
          logger.error(uuid, msg);
        }
      }
      if (totalBatches > 1 && batchNum < totalBatches) log();
      continue;
    }
    spinner.stop();

    // 2. Upload exported assets
    await uploadExported(batchResult);

    // Batch separator when multiple batches
    if (totalBatches > 1 && batchNum < totalBatches) {
      log();
    }
  }

  // Retry deferred assets
  if (deferred.length > 0 && !signal.aborted) {
    log();
    log(`  Retrying ${deferred.length} deferred assets...`);
    for (const uuid of deferred) {
      if (signal.aborted) break;
      const assetBytes = assetByUuid.get(uuid)?.originalFileSize ?? 0;
      exporter.setEstimatedBatchBytes?.(assetBytes);
      try {
        const result = await exporter.exportBatch([uuid], signal);
        await uploadExported(result);
      } catch (retryError: unknown) {
        if (signal.aborted) break;
        const msg = retryError instanceof Error
          ? retryError.message
          : String(retryError);
        log(`    Failed: ${assetLabel(uuid)} — ${msg}`);
        report.errors.push({ uuid, message: msg });
        report.failed++;
        logger.error(uuid, msg);
      }
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
