import { assertEquals, assertRejects } from "@std/assert";
import { withRetry } from "./retry.ts";
import { AbortError } from "./abort-error.ts";

Deno.test("withRetry: returns result on first success", async () => {
  const result = await withRetry(() => Promise.resolve(42));
  assertEquals(result, 42);
});

Deno.test("withRetry: retries on transient error then succeeds", async () => {
  let attempt = 0;
  const result = await withRetry(
    () => {
      attempt++;
      if (attempt === 1) throw new Error("fetch failed");
      return Promise.resolve("ok");
    },
    { baseDelayMs: 10 },
  );
  assertEquals(result, "ok");
  assertEquals(attempt, 2);
});

Deno.test("withRetry: does not retry on non-transient error", async () => {
  let attempt = 0;
  await assertRejects(
    () =>
      withRetry(
        () => {
          attempt++;
          throw new Error("Access denied");
        },
        { baseDelayMs: 10 },
      ),
    Error,
    "Access denied",
  );
  assertEquals(attempt, 1);
});

Deno.test("withRetry: throws after max attempts", async () => {
  let attempt = 0;
  await assertRejects(
    () =>
      withRetry(
        () => {
          attempt++;
          throw new Error("ECONNRESET");
        },
        { maxAttempts: 3, baseDelayMs: 10 },
      ),
    Error,
    "ECONNRESET",
  );
  assertEquals(attempt, 3);
});

Deno.test("withRetry: respects abort signal during backoff", async () => {
  const controller = new AbortController();
  let attempt = 0;

  // Abort after 50ms — the backoff would be 100ms so it should interrupt
  setTimeout(() => controller.abort(), 50);

  await assertRejects(
    () =>
      withRetry(
        () => {
          attempt++;
          throw new Error("timeout");
        },
        { maxAttempts: 5, baseDelayMs: 100, signal: controller.signal },
      ),
    AbortError,
  );
  // Should have attempted once, then aborted during the first backoff delay
  assertEquals(attempt, 1);
});

Deno.test("withRetry: stops retrying when signal already aborted", async () => {
  const controller = new AbortController();
  controller.abort();

  let attempt = 0;
  await assertRejects(
    () =>
      withRetry(
        () => {
          attempt++;
          throw new Error("timeout");
        },
        { signal: controller.signal, baseDelayMs: 10 },
      ),
    Error,
    "timeout",
  );
  // Should attempt once, then see signal is aborted and not retry
  assertEquals(attempt, 1);
});
