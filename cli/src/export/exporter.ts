import { join } from "@std/path/join";
import { AbortError } from "../abort-error.ts";

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
  exportBatch(
    uuids: string[],
    signal?: AbortSignal,
  ): Promise<ExportBatchResult>;
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

/** Default timeout for the ladder subprocess (5 minutes). */
const LADDER_TIMEOUT_MS = 5 * 60 * 1000;

/** Create an exporter that shells out to the ladder binary. */
export function createLadderExporter(
  ladderPath: string,
  stagingDir: string = DEFAULT_STAGING_DIR,
  timeoutMs: number = LADDER_TIMEOUT_MS,
): Exporter & { stagingDir: string } {
  return {
    stagingDir,

    async exportBatch(
      uuids: string[],
      signal?: AbortSignal,
    ): Promise<ExportBatchResult> {
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

      // Race the subprocess against timeout and abort signal
      const result = await raceSubprocess(process, timeoutMs, signal);

      if (result.code !== 0) {
        const err = new TextDecoder().decode(result.stderr);
        throw new Error(
          `ladder exited with code ${result.code}: ${err.trim()}`,
        );
      }

      const output = new TextDecoder().decode(result.stdout);
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

/** Race a subprocess against a timeout and optional abort signal.
 *  Kills the process on timeout or abort.
 *  Cleans up timer and listeners on completion to prevent leaks. */
export async function raceSubprocess(
  process: Deno.ChildProcess,
  timeoutMs: number,
  signal?: AbortSignal,
): Promise<Deno.CommandOutput> {
  signal?.throwIfAborted();

  const outputPromise = process.output();

  let removeAbortListener: (() => void) | undefined;
  const abortPromise = signal
    ? new Promise<never>((_resolve, reject) => {
      const onAbort = () => reject(new AbortError("Backup interrupted"));
      if (signal.aborted) {
        onAbort();
        return;
      }
      signal.addEventListener("abort", onAbort, { once: true });
      removeAbortListener = () => signal.removeEventListener("abort", onAbort);
    })
    : null;

  let timeoutId: number | undefined;
  const timeoutPromise = new Promise<never>((_resolve, reject) => {
    timeoutId = setTimeout(() => {
      reject(
        new Error(`Ladder subprocess timed out after ${timeoutMs / 1000}s`),
      );
    }, timeoutMs);
    Deno.unrefTimer(timeoutId);
  });

  const racers: Promise<Deno.CommandOutput>[] = [outputPromise, timeoutPromise];
  if (abortPromise) racers.push(abortPromise);

  try {
    return await Promise.race(racers);
  } catch (err) {
    // Kill the subprocess on timeout or abort
    try {
      process.kill("SIGTERM");
    } catch {
      // Process may have already exited
    }
    throw err;
  } finally {
    clearTimeout(timeoutId);
    removeAbortListener?.();
  }
}
