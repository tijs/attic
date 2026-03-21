import { assertEquals, assertRejects } from "@std/assert";
import type { ExportBatchResult } from "./exporter.ts";
import { exportWithSubdivision } from "./exporter.ts";

/** A spawn function that always succeeds, returning one result per UUID. */
function succeedingSpawn(
  uuids: string[],
  _signal?: AbortSignal,
): Promise<ExportBatchResult> {
  return Promise.resolve({
    results: uuids.map((uuid) => ({
      uuid,
      path: `/staging/${uuid}.heic`,
      size: 1024,
      sha256: "abc123",
    })),
    errors: [],
  });
}

/** A spawn function that times out N times, then succeeds. */
function timeoutThenSucceed(
  timesBeforeSuccess: number,
): (uuids: string[], signal?: AbortSignal) => Promise<ExportBatchResult> {
  let callCount = 0;
  return (uuids, signal) => {
    callCount++;
    if (callCount <= timesBeforeSuccess) {
      return Promise.reject(
        new Error("Ladder subprocess timed out after 300s"),
      );
    }
    return succeedingSpawn(uuids, signal);
  };
}

/** A spawn function that always times out. */
function alwaysTimeout(
  _uuids: string[],
  _signal?: AbortSignal,
): Promise<ExportBatchResult> {
  return Promise.reject(
    new Error("Ladder subprocess timed out after 300s"),
  );
}

/** A spawn function that fails with a non-timeout error. */
function crashingSpawn(
  _uuids: string[],
  _signal?: AbortSignal,
): Promise<ExportBatchResult> {
  return Promise.reject(new Error("ladder exited with code 1: segfault"));
}

Deno.test("exportWithSubdivision: passes through on success", async () => {
  const result = await exportWithSubdivision(
    succeedingSpawn,
    ["a", "b", "c"],
  );
  assertEquals(result.results.length, 3);
  assertEquals(result.errors.length, 0);
});

Deno.test("exportWithSubdivision: subdivides on timeout", async () => {
  const subdivisions: Array<{ size: number; parts: number }> = [];
  // Times out once (full batch of 10), then succeeds on both halves
  const spawn = timeoutThenSucceed(1);

  const result = await exportWithSubdivision(
    spawn,
    ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"],
    undefined,
    (size, parts) => subdivisions.push({ size, parts }),
  );

  assertEquals(result.results.length, 10);
  assertEquals(result.errors.length, 0);
  assertEquals(subdivisions.length, 1);
  assertEquals(subdivisions[0].size, 10);
  assertEquals(subdivisions[0].parts, 2);
});

Deno.test("exportWithSubdivision: stops at max depth and reports failures", async () => {
  const subdivisions: Array<{ size: number; parts: number }> = [];

  const result = await exportWithSubdivision(
    alwaysTimeout,
    ["a", "b", "c", "d"],
    undefined,
    (size, parts) => subdivisions.push({ size, parts }),
  );

  // All should be reported as failed after exhausting subdivision depth
  assertEquals(result.results.length, 0);
  assertEquals(result.errors.length, 4);
  for (const err of result.errors) {
    assertEquals(err.message, "Export timed out after subdivision retries");
  }
  // depth 0 -> 1 -> 2 -> 3 (max), should have subdivided at each level
  assertEquals(subdivisions.length >= 3, true);
});

Deno.test("exportWithSubdivision: non-timeout errors are NOT retried", async () => {
  await assertRejects(
    () =>
      exportWithSubdivision(
        crashingSpawn,
        ["a", "b"],
      ),
    Error,
    "segfault",
  );
});

Deno.test("exportWithSubdivision: respects abort signal", async () => {
  const controller = new AbortController();
  // Timeout once to trigger subdivision, then abort before second half
  let callCount = 0;
  const spawn = (
    uuids: string[],
    _signal?: AbortSignal,
  ): Promise<ExportBatchResult> => {
    callCount++;
    if (callCount === 1) {
      return Promise.reject(
        new Error("Ladder subprocess timed out after 300s"),
      );
    }
    // After first subdivision succeeds, abort before second chunk
    controller.abort();
    return succeedingSpawn(uuids);
  };

  const result = await exportWithSubdivision(
    spawn,
    ["a", "b", "c", "d"],
    controller.signal,
  );

  // Should have partial results — first half succeeded, second half skipped
  assertEquals(result.results.length, 2);
  assertEquals(result.errors.length, 0);
});
