import { AbortError } from "./abort-error.ts";

export interface RetryOptions {
  maxAttempts?: number;
  baseDelayMs?: number;
  signal?: AbortSignal;
}

/** Retry an async operation with exponential backoff.
 *  Handles transient network failures (e.g. after sleep/wake).
 *  Respects an optional AbortSignal to bail out immediately. */
export async function withRetry<T>(
  fn: () => Promise<T>,
  opts: RetryOptions = {},
): Promise<T> {
  const { maxAttempts = 3, baseDelayMs = 1000, signal } = opts;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (error: unknown) {
      if (attempt === maxAttempts) throw error;

      // Don't retry if we've been aborted
      if (signal?.aborted) throw error;

      // Only retry on transient/network errors, not permission or validation errors
      const msg = error instanceof Error ? error.message : String(error);
      const isTransient =
        /timeout|ECONNRESET|ECONNREFUSED|EPIPE|socket|network|fetch failed/i
          .test(msg);
      if (!isTransient) throw error;

      const delay = baseDelayMs * Math.pow(2, attempt - 1);
      await abortableDelay(delay, signal);
    }
  }
  throw new Error("unreachable");
}

/** Sleep that can be interrupted by an AbortSignal. */
function abortableDelay(ms: number, signal?: AbortSignal): Promise<void> {
  if (!signal) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new AbortError("Retry aborted"));
      return;
    }
    const id = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    function onAbort() {
      clearTimeout(id);
      reject(new AbortError("Retry aborted"));
    }
    signal.addEventListener("abort", onAbort, { once: true });
  });
}
