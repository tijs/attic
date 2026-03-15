import type { PhotoAsset } from "@attic/shared";
import { buildMetadataJson, metadataKey } from "@attic/shared";
import type { Manifest } from "../manifest/manifest.ts";
import type { S3Provider } from "../storage/s3-client.ts";
import { formatBytes } from "../format.ts";
import { withRetry } from "../retry.ts";

export interface RefreshMetadataOptions {
  /** Maximum concurrent uploads. */
  concurrency: number;
  /** Show what would be uploaded without uploading. */
  dryRun: boolean;
}

const DEFAULT_OPTIONS: RefreshMetadataOptions = {
  concurrency: 20,
  dryRun: false,
};

export interface RefreshMetadataReport {
  updated: number;
  skipped: number;
  failed: number;
  totalBytes: number;
  errors: Array<{ uuid: string; message: string }>;
}

/**
 * Re-upload metadata JSON for already-backed-up assets.
 * Original files and manifest are left untouched.
 */
export async function refreshMetadata(
  assets: PhotoAsset[],
  manifest: Manifest,
  s3: S3Provider,
  opts: Partial<RefreshMetadataOptions> = {},
): Promise<RefreshMetadataReport> {
  const options = { ...DEFAULT_OPTIONS, ...opts };
  options.concurrency = Math.max(1, options.concurrency);

  // Only refresh assets that are in the manifest
  const assetByUuid = new Map<string, PhotoAsset>();
  for (const a of assets) {
    assetByUuid.set(a.uuid, a);
  }

  const toRefresh: Array<
    { asset: PhotoAsset; s3Key: string; checksum: string; backedUpAt: string }
  > = [];
  for (const [uuid, entry] of Object.entries(manifest.entries)) {
    const asset = assetByUuid.get(uuid);
    if (asset) {
      toRefresh.push({
        asset,
        s3Key: entry.s3Key,
        checksum: entry.checksum,
        backedUpAt: entry.backedUpAt,
      });
    }
  }

  console.log(`\n  Attic — Refresh Metadata`);
  console.log(`  ════════════════════════\n`);
  console.log(
    `  Backed-up assets in DB:  ${toRefresh.length.toLocaleString()}`,
  );
  if (options.dryRun) console.log(`  Mode:                    DRY RUN`);
  console.log();

  if (toRefresh.length === 0) {
    console.log("  Nothing to refresh — no backed-up assets found in DB.\n");
    return { updated: 0, skipped: 0, failed: 0, totalBytes: 0, errors: [] };
  }

  if (options.dryRun) {
    return {
      updated: 0,
      skipped: toRefresh.length,
      failed: 0,
      totalBytes: 0,
      errors: [],
    };
  }

  const report: RefreshMetadataReport = {
    updated: 0,
    skipped: 0,
    failed: 0,
    totalBytes: 0,
    errors: [],
  };

  // Process with bounded concurrency using an index counter (O(1) per item).
  // Mutations to `report` are safe: Deno is single-threaded, and all
  // increments happen synchronously between await points.
  let cursor = 0;
  const workers = Array.from(
    { length: Math.min(options.concurrency, toRefresh.length) },
    async () => {
      while (cursor < toRefresh.length) {
        const item = toRefresh[cursor++];
        try {
          const meta = buildMetadataJson(
            item.asset,
            item.s3Key,
            item.checksum,
            item.backedUpAt,
          );
          const data = new TextEncoder().encode(
            JSON.stringify(meta, null, 2),
          );
          await withRetry(() =>
            s3.putObject(
              metadataKey(item.asset.uuid),
              data,
              "application/json",
            )
          );
          report.updated++;
          report.totalBytes += data.byteLength;
        } catch (error: unknown) {
          const msg = error instanceof Error ? error.message : "Unknown error";
          report.errors.push({ uuid: item.asset.uuid, message: msg });
          report.failed++;
        }

        const done = report.updated + report.failed;
        if (done % 50 === 0 || done === toRefresh.length) {
          const pct = ((done / toRefresh.length) * 100).toFixed(1);
          console.log(
            `    Progress: ${done}/${toRefresh.length} (${pct}%)  ` +
              `Uploaded: ${formatBytes(report.totalBytes)}`,
          );
        }
      }
    },
  );

  await Promise.all(workers);

  console.log(`\n  ── Complete ──`);
  console.log(`  Updated:   ${report.updated.toLocaleString()}`);
  console.log(`  Failed:    ${report.failed.toLocaleString()}`);
  console.log(`  Total:     ${formatBytes(report.totalBytes)}\n`);

  return report;
}
