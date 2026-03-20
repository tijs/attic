import type { PhotoAsset } from "@attic/shared";
import type { Manifest } from "../manifest/manifest.ts";
import { isBackedUp } from "../manifest/manifest.ts";
import { formatBytes } from "../format.ts";

/** Get the best-known size for an asset: Photos DB first, manifest fallback. */
function assetSize(asset: PhotoAsset, manifest: Manifest): number {
  if (asset.originalFileSize && asset.originalFileSize > 0) {
    return asset.originalFileSize;
  }
  return manifest.entries[asset.uuid]?.size ?? 0;
}

export function printStatusReport(
  assets: PhotoAsset[],
  manifest: Manifest,
): void {
  const backedUp = assets.filter((a) => isBackedUp(manifest, a.uuid));
  const pending = assets.filter((a) => !isBackedUp(manifest, a.uuid));

  const totalSize = assets.reduce(
    (sum, a) => sum + assetSize(a, manifest),
    0,
  );
  const backedUpSize = backedUp.reduce(
    (sum, a) => sum + assetSize(a, manifest),
    0,
  );
  const pendingSize = pending.reduce(
    (sum, a) => sum + assetSize(a, manifest),
    0,
  );

  console.log(`\n  Attic — Backup Status`);
  console.log(`  ═════════════════════\n`);
  console.log(
    `  Total assets:    ${assets.length.toLocaleString()}  (${
      formatBytes(totalSize)
    })`,
  );
  console.log(
    `  Backed up:       ${backedUp.length.toLocaleString()}  (${
      formatBytes(backedUpSize)
    })`,
  );
  console.log(
    `  Pending:         ${pending.length.toLocaleString()}  (${
      formatBytes(pendingSize)
    })`,
  );

  const pct = assets.length > 0
    ? ((backedUp.length / assets.length) * 100).toFixed(1)
    : "0.0";
  console.log(`\n  Progress:        ${pct}%\n`);
}
