import { assertEquals } from "@std/assert";
import {
  isTimeoutError,
  LadderTimeoutError,
  timeoutForBytes,
} from "./exporter.ts";

Deno.test("timeoutForBytes: scales with size", () => {
  // Small batch: base timeout (10 min) + 1 min for < 100 MB
  assertEquals(timeoutForBytes(50 * 1024 * 1024), 10 * 60_000 + 60_000);
  // 500 MB batch: base + 5 min
  assertEquals(timeoutForBytes(500 * 1024 * 1024), 10 * 60_000 + 5 * 60_000);
  // 0 bytes: just base
  assertEquals(timeoutForBytes(0), 10 * 60_000);
  // Negative bytes: treated as 0
  assertEquals(timeoutForBytes(-100), 10 * 60_000);
});

Deno.test("isTimeoutError: detects LadderTimeoutError", () => {
  assertEquals(isTimeoutError(new LadderTimeoutError(300_000)), true);
  assertEquals(isTimeoutError(new Error("connection reset")), false);
  assertEquals(isTimeoutError(new Error("timed out")), false); // plain Error, not LadderTimeoutError
  assertEquals(isTimeoutError("not an error"), false);
});
