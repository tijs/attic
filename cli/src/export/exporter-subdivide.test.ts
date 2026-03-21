import { assertEquals } from "@std/assert";
import { isTimeoutError, timeoutForBytes } from "./exporter.ts";

Deno.test("timeoutForBytes: scales with size", () => {
  // Small batch: base timeout (5 min) + 1 min for < 100 MB
  assertEquals(timeoutForBytes(50 * 1024 * 1024), 5 * 60_000 + 60_000);
  // 500 MB batch: base + 5 min
  assertEquals(timeoutForBytes(500 * 1024 * 1024), 5 * 60_000 + 5 * 60_000);
  // 0 bytes: just base
  assertEquals(timeoutForBytes(0), 5 * 60_000);
});

Deno.test("isTimeoutError: detects timeout errors", () => {
  assertEquals(
    isTimeoutError(new Error("Ladder subprocess timed out after 300s")),
    true,
  );
  assertEquals(isTimeoutError(new Error("something timed out")), true);
  assertEquals(isTimeoutError(new Error("connection reset")), false);
  assertEquals(isTimeoutError("not an error"), false);
});
