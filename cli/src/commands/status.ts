import type { PhotoAsset } from "@attic/shared";
import type { ManifestStore } from "../manifest/manifest.ts";
import { isBackedUp } from "../manifest/manifest.ts";
import { formatBytes } from "../format.ts";

export async function printStatusReport(
  assets: PhotoAsset[],
  manifestStore: ManifestStore,
): Promise<void> {
  const manifest = await manifestStore.load();

  const backedUp = assets.filter((a) => isBackedUp(manifest, a.uuid));
  const pending = assets.filter((a) => !isBackedUp(manifest, a.uuid));

  const totalSize = assets.reduce(
    (sum, a) => sum + (a.originalFileSize ?? 0),
    0,
  );
  const backedUpSize = backedUp.reduce(
    (sum, a) => sum + (a.originalFileSize ?? 0),
    0,
  );
  const pendingSize = pending.reduce(
    (sum, a) => sum + (a.originalFileSize ?? 0),
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
