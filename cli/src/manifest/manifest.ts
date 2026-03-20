import { join } from "@std/path/join";
import type { S3Provider } from "../storage/s3-client.ts";

export interface ManifestEntry {
  uuid: string;
  s3Key: string;
  checksum: string;
  backedUpAt: string;
  size?: number;
}

export interface Manifest {
  entries: Record<string, ManifestEntry>;
}

export interface ManifestStore {
  load(): Promise<Manifest>;
  save(manifest: Manifest): Promise<void>;
}

/** S3 key where the shared manifest is stored. */
export const MANIFEST_S3_KEY = "manifest.json";

/** Check whether an asset has been backed up. */
export function isBackedUp(manifest: Manifest, uuid: string): boolean {
  return uuid in manifest.entries;
}

/** Mark an asset as backed up (mutates in place). */
export function markBackedUp(
  manifest: Manifest,
  uuid: string,
  checksum: string,
  s3Key: string,
  size?: number,
  backedUpAt?: string,
): void {
  manifest.entries[uuid] = {
    uuid,
    s3Key,
    checksum,
    backedUpAt: backedUpAt ?? new Date().toISOString(),
    ...(size != null ? { size } : {}),
  };
}

function assertManifest(data: unknown): asserts data is Manifest {
  if (typeof data !== "object" || data === null) {
    throw new Error("Invalid manifest file: expected a JSON object");
  }
  const obj = data as Record<string, unknown>;
  if (typeof obj.entries !== "object" || obj.entries === null) {
    throw new Error("Invalid manifest file: missing or invalid 'entries'");
  }
}

/** Create a manifest store backed by S3. This is the primary store. */
export function createS3ManifestStore(
  s3: S3Provider,
  key: string = MANIFEST_S3_KEY,
): ManifestStore {
  return {
    async load(): Promise<Manifest> {
      try {
        const data = await s3.getObject(key);
        const text = new TextDecoder().decode(data);
        const parsed: unknown = JSON.parse(text);
        assertManifest(parsed);
        return parsed;
      } catch (error: unknown) {
        if (isNotFoundError(error)) {
          return { entries: {} };
        }
        throw error;
      }
    },

    async save(manifest: Manifest): Promise<void> {
      const json = JSON.stringify(manifest, null, 2) + "\n";
      const data = new TextEncoder().encode(json);
      await s3.putObject(key, data, "application/json");
    },
  };
}

function isNotFoundError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  return error.name === "NoSuchKey" || error.name === "NotFound";
}

/** Load manifest from S3, migrating from local file if needed.
 *
 * Migration flow (one-time):
 * 1. If S3 has a manifest with entries, use it.
 * 2. If S3 is empty, check for a local manifest at ~/.attic/manifest.json.
 * 3. If local exists, upload it to S3 and return it.
 * 4. If neither exists, return empty manifest.
 */
export async function loadManifestWithMigration(
  s3Store: ManifestStore,
  localDir?: string,
): Promise<Manifest> {
  const s3Manifest = await s3Store.load();

  if (Object.keys(s3Manifest.entries).length > 0) {
    return s3Manifest;
  }

  // Check for local manifest to migrate
  const dir = localDir ??
    join(Deno.env.get("HOME") ?? "~", ".attic");
  const localPath = join(dir, "manifest.json");

  try {
    const text = await Deno.readTextFile(localPath);
    const data: unknown = JSON.parse(text);
    assertManifest(data);

    if (Object.keys(data.entries).length > 0) {
      console.log(
        `  Migrating local manifest (${
          Object.keys(data.entries).length
        } entries) to S3...`,
      );
      await s3Store.save(data);
      console.log(`  Migration complete.\n`);
      return data;
    }
  } catch {
    // No local manifest or unreadable — that's fine
  }

  return s3Manifest;
}
