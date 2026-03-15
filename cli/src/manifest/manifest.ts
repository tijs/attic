import { join } from "@std/path/join";

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
  /** Path to the manifest file on disk. */
  readonly filePath: string;
  load(): Promise<Manifest>;
  save(manifest: Manifest): Promise<void>;
}

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

const DEFAULT_DIR = join(
  Deno.env.get("HOME") ?? "~",
  ".attic",
);

export function createManifestStore(
  dir: string = DEFAULT_DIR,
): ManifestStore {
  const filePath = join(dir, "manifest.json");

  return {
    filePath,

    async load(): Promise<Manifest> {
      try {
        const text = await Deno.readTextFile(filePath);
        const data: unknown = JSON.parse(text);
        assertManifest(data);
        return data;
      } catch (error: unknown) {
        if (error instanceof Deno.errors.NotFound) {
          return { entries: {} };
        }
        throw error;
      }
    },

    async save(manifest: Manifest): Promise<void> {
      await Deno.mkdir(dir, { recursive: true });
      const tmpPath = filePath + ".tmp";
      await Deno.writeTextFile(
        tmpPath,
        JSON.stringify(manifest, null, 2) + "\n",
      );
      await Deno.rename(tmpPath, filePath);
    },
  };
}
