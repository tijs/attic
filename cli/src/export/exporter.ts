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

/** Maximum subdivision depth when retrying timed-out batches. */
const MAX_SUBDIVIDE_DEPTH = 3;

/** Options for creating a ladder exporter. */
export interface LadderExporterOptions {
  stagingDir?: string;
  timeoutMs?: number;
  /** Called when a timed-out batch is subdivided for retry. */
  onSubdivide?: (originalSize: number, parts: number) => void;
}

/** Spawn a single ladder process and return the parsed result. */
async function spawnLadder(
  ladderPath: string,
  uuids: string[],
  stagingDir: string,
  timeoutMs: number,
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
}

function isTimeoutError(error: unknown): boolean {
  return error instanceof Error && /timed out/i.test(error.message);
}

/** Try a batch; on timeout, split in half and retry each half recursively.
 *  Stops at MAX_SUBDIVIDE_DEPTH and reports remaining UUIDs as failed. */
export async function exportWithSubdivision(
  spawn: (uuids: string[], signal?: AbortSignal) => Promise<ExportBatchResult>,
  uuids: string[],
  signal?: AbortSignal,
  onSubdivide?: (originalSize: number, parts: number) => void,
  depth: number = 0,
): Promise<ExportBatchResult> {
  try {
    return await spawn(uuids, signal);
  } catch (error: unknown) {
    if (!isTimeoutError(error)) throw error;
    if (depth >= MAX_SUBDIVIDE_DEPTH) {
      // Give up — report all UUIDs in this chunk as failed
      return {
        results: [],
        errors: uuids.map((uuid) => ({
          uuid,
          message: "Export timed out after subdivision retries",
        })),
      };
    }

    const mid = Math.ceil(uuids.length / 2);
    const parts = uuids.length <= mid ? 1 : 2;
    onSubdivide?.(uuids.length, parts);

    const left = uuids.slice(0, mid);
    const right = uuids.slice(mid);
    const chunks = right.length > 0 ? [left, right] : [left];

    const combined: ExportBatchResult = { results: [], errors: [] };
    for (const chunk of chunks) {
      if (signal?.aborted) break;
      const result = await exportWithSubdivision(
        spawn,
        chunk,
        signal,
        onSubdivide,
        depth + 1,
      );
      combined.results.push(...result.results);
      combined.errors.push(...result.errors);
    }
    return combined;
  }
}

/** Create an exporter that shells out to the ladder binary. */
export function createLadderExporter(
  ladderPath: string,
  opts: LadderExporterOptions = {},
): Exporter & { stagingDir: string } {
  const stagingDir = opts.stagingDir ?? DEFAULT_STAGING_DIR;
  const timeoutMs = opts.timeoutMs ?? LADDER_TIMEOUT_MS;
  const onSubdivide = opts.onSubdivide;

  const spawn = (uuids: string[], signal?: AbortSignal) =>
    spawnLadder(ladderPath, uuids, stagingDir, timeoutMs, signal);

  return {
    stagingDir,

    exportBatch(
      uuids: string[],
      signal?: AbortSignal,
    ): Promise<ExportBatchResult> {
      return exportWithSubdivision(spawn, uuids, signal, onSubdivide);
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
