import type { PhotoAsset } from "@attic/shared";
import { AssetKind, CloudLocalState } from "@attic/shared";
import { formatBytes } from "../format.ts";

export function printScanReport(assets: PhotoAsset[]): void {
  const totalSize = assets.reduce(
    (sum, a) => sum + (a.originalFileSize ?? 0),
    0,
  );

  const photos = assets.filter((a) => a.kind === AssetKind.PHOTO);
  const videos = assets.filter((a) => a.kind === AssetKind.VIDEO);
  const photoSize = photos.reduce(
    (sum, a) => sum + (a.originalFileSize ?? 0),
    0,
  );
  const videoSize = videos.reduce(
    (sum, a) => sum + (a.originalFileSize ?? 0),
    0,
  );

  const local = assets.filter(
    (a) => a.cloudLocalState === CloudLocalState.LOCAL,
  );
  const icloudOnly = assets.filter(
    (a) => a.cloudLocalState === CloudLocalState.ICLOUD_ONLY,
  );

  const favorites = assets.filter((a) => a.favorite);

  // Type breakdown
  const typeGroups = new Map<string, number>();
  for (const asset of assets) {
    const type = asset.uniformTypeIdentifier ?? "unknown";
    typeGroups.set(type, (typeGroups.get(type) ?? 0) + 1);
  }
  const sortedTypes = [...typeGroups.entries()].sort((a, b) => b[1] - a[1]);

  console.log(`\n  Attic — Library Scan`);
  console.log(`  ════════════════════\n`);
  console.log(`  Total assets:    ${assets.length.toLocaleString()}`);
  console.log(`  Total size:      ${formatBytes(totalSize)}\n`);

  console.log(
    `  Photos:          ${photos.length.toLocaleString()}  (${
      formatBytes(photoSize)
    })`,
  );
  console.log(
    `  Videos:          ${videos.length.toLocaleString()}  (${
      formatBytes(videoSize)
    })\n`,
  );

  console.log(`  Local originals: ${local.length.toLocaleString()}`);
  console.log(
    `  iCloud only:     ${icloudOnly.length.toLocaleString()}\n`,
  );

  const edited = assets.filter((a) => a.hasEdit);
  console.log(`  Favorites:       ${favorites.length.toLocaleString()}`);
  console.log(`  Edited:          ${edited.length.toLocaleString()}\n`);

  console.log(`  Types:`);
  for (const [type, count] of sortedTypes.slice(0, 10)) {
    console.log(`    ${type.padEnd(40)} ${count.toLocaleString()}`);
  }
  if (sortedTypes.length > 10) {
    console.log(`    ... and ${sortedTypes.length - 10} more types`);
  }
  console.log();
}
