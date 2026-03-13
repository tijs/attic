import type {
  Manifest,
  ManifestEntry,
  ManifestStore,
} from "../manifest/manifest.ts";
import { markBackedUp } from "../manifest/manifest.ts";
import type { S3Provider } from "../storage/s3-client.ts";

const UUID_PATTERN = /^[A-Za-z0-9._-]+$/;
const S3_KEY_PATTERN = /^originals\/\d{4}\/\d{2}\/[A-Za-z0-9._-]+\.[a-z0-9]+$/;
const CHECKSUM_PATTERN = /^sha256:[a-f0-9]{64}$/;

/** Rebuild manifest from S3 metadata JSON files. */
export async function rebuildManifest(
  s3: S3Provider,
  manifestStore: ManifestStore,
): Promise<Manifest> {
  console.log(`\n  Attic — Rebuild Manifest`);
  console.log(`  ═══════════════════════\n`);
  console.log(`  Scanning S3 for metadata files...\n`);

  const manifest: Manifest = { entries: {} };
  let count = 0;

  for await (const obj of s3.listObjects("metadata/assets/")) {
    if (!obj.key.endsWith(".json")) continue;

    try {
      const data = await s3.getObject(obj.key);
      const text = new TextDecoder().decode(data);
      const meta: unknown = JSON.parse(text);
      const entry = parseMetadataToEntry(meta);
      if (entry) {
        markBackedUp(
          manifest,
          entry.uuid,
          entry.checksum,
          entry.s3Key,
          entry.size,
          entry.backedUpAt,
        );
        count++;
      }
    } catch {
      console.error(`  Warning: failed to parse ${obj.key}`);
    }

    if (count % 100 === 0 && count > 0) {
      console.log(`  Recovered ${count} entries...`);
    }
  }

  await manifestStore.save(manifest);

  console.log(`\n  Rebuilt manifest with ${count.toLocaleString()} entries.\n`);

  return manifest;
}

/** Extract a ManifestEntry from an S3 metadata JSON object. Validates format. */
function parseMetadataToEntry(
  data: unknown,
): ManifestEntry | null {
  if (typeof data !== "object" || data === null) return null;
  const obj = data as Record<string, unknown>;
  if (
    typeof obj.uuid !== "string" ||
    typeof obj.s3Key !== "string" ||
    typeof obj.checksum !== "string"
  ) {
    return null;
  }

  // Validate field formats
  if (!UUID_PATTERN.test(obj.uuid)) return null;
  if (!S3_KEY_PATTERN.test(obj.s3Key)) return null;
  if (!CHECKSUM_PATTERN.test(obj.checksum)) return null;

  return {
    uuid: obj.uuid,
    s3Key: obj.s3Key,
    checksum: obj.checksum,
    backedUpAt: typeof obj.backedUpAt === "string"
      ? obj.backedUpAt
      : new Date().toISOString(),
    size: typeof obj.fileSize === "number" ? obj.fileSize : undefined,
  };
}
