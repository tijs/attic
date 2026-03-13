import { join } from "@std/path/join";

/** Result of exporting a single asset via ladder. */
export interface ExportedAsset {
  uuid: string;
  path: string;
  size: number;
  sha256: string;
}

/** Error from ladder for a single asset. */
export interface ExportError {
  uuid: string;
  message: string;
}

/** Combined result from a ladder export batch. */
export interface ExportBatchResult {
  results: ExportedAsset[];
  errors: ExportError[];
}

/** Abstraction over the ladder binary for testability. */
export interface Exporter {
  /** Export a batch of assets by UUID to the staging directory. */
  exportBatch(uuids: string[]): Promise<ExportBatchResult>;
}

const DEFAULT_STAGING_DIR = join(
  Deno.env.get("HOME") ?? "~",
  ".attic",
  "staging",
);

/** Remove a staged file, ignoring NotFound errors. Path must be inside stagingDir. */
export async function removeStagedFile(
  path: string,
  stagingDir: string,
): Promise<void> {
  // Resolve symlinks (e.g. /var -> /private/var on macOS) for both paths.
  // For the file path, resolve its parent dir if the file itself doesn't exist.
  const parentDir = path.substring(0, path.lastIndexOf("/"));
  const fileName = path.substring(path.lastIndexOf("/") + 1);
  const resolvedParent = await Deno.realPath(parentDir).catch(() => parentDir);
  const resolvedPath = `${resolvedParent}/${fileName}`;
  const resolvedDir = await Deno.realPath(stagingDir).catch(() => stagingDir);
  if (
    !resolvedPath.startsWith(resolvedDir + "/") && resolvedPath !== resolvedDir
  ) {
    throw new Error(
      `Refusing to delete file outside staging directory: ${path}`,
    );
  }
  try {
    await Deno.remove(path);
  } catch (error: unknown) {
    if (!(error instanceof Deno.errors.NotFound)) {
      throw error;
    }
  }
}

/** Validate that ladder output conforms to ExportBatchResult shape. */
function assertExportBatchResult(
  data: unknown,
): asserts data is ExportBatchResult {
  if (data == null || typeof data !== "object") {
    throw new Error("Ladder output is not an object");
  }
  const obj = data as Record<string, unknown>;
  if (!Array.isArray(obj.results)) {
    throw new Error("Ladder output missing 'results' array");
  }
  if (!Array.isArray(obj.errors)) {
    throw new Error("Ladder output missing 'errors' array");
  }
  for (const r of obj.results) {
    if (
      typeof r !== "object" || r == null ||
      typeof (r as Record<string, unknown>).uuid !== "string" ||
      typeof (r as Record<string, unknown>).path !== "string" ||
      typeof (r as Record<string, unknown>).size !== "number" ||
      typeof (r as Record<string, unknown>).sha256 !== "string"
    ) {
      throw new Error(
        `Invalid result entry in ladder output: ${JSON.stringify(r)}`,
      );
    }
  }
  for (const e of obj.errors) {
    if (
      typeof e !== "object" || e == null ||
      typeof (e as Record<string, unknown>).uuid !== "string" ||
      typeof (e as Record<string, unknown>).message !== "string"
    ) {
      throw new Error(
        `Invalid error entry in ladder output: ${JSON.stringify(e)}`,
      );
    }
  }
}

/** Strip the "/L0/001" suffix from a PhotoKit local identifier, returning the bare UUID. */
function stripLocalIdSuffix(id: string): string {
  const slashIndex = id.indexOf("/");
  return slashIndex === -1 ? id : id.substring(0, slashIndex);
}

/** Create an exporter that shells out to the ladder binary. */
export function createLadderExporter(
  ladderPath: string,
  stagingDir: string = DEFAULT_STAGING_DIR,
): Exporter & { stagingDir: string } {
  return {
    stagingDir,

    async exportBatch(uuids: string[]): Promise<ExportBatchResult> {
      await Deno.mkdir(stagingDir, { recursive: true });

      // PhotoKit expects local identifiers in "UUID/L0/001" format
      const photoKitIds = uuids.map((uuid) => `${uuid}/L0/001`);

      const request = JSON.stringify({
        uuids: photoKitIds,
        stagingDir,
      });

      const cmd = new Deno.Command(ladderPath, {
        stdin: "piped",
        stdout: "piped",
        stderr: "piped",
      });

      const process = cmd.spawn();

      const writer = process.stdin.getWriter();
      await writer.write(new TextEncoder().encode(request));
      await writer.close();

      const { code, stdout, stderr } = await process.output();

      if (code !== 0) {
        const err = new TextDecoder().decode(stderr);
        throw new Error(`ladder exited with code ${code}: ${err.trim()}`);
      }

      const output = new TextDecoder().decode(stdout);
      const parsed: unknown = JSON.parse(output);
      assertExportBatchResult(parsed);

      // Map PhotoKit identifiers ("UUID/L0/001") back to bare UUIDs
      for (const r of parsed.results) {
        r.uuid = stripLocalIdSuffix(r.uuid);
      }
      for (const e of parsed.errors) {
        e.uuid = stripLocalIdSuffix(e.uuid);
      }

      return parsed;
    },
  };
}
