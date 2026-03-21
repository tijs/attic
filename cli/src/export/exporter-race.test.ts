import { assertEquals, assertRejects } from "@std/assert";
import { LadderTimeoutError, raceSubprocess } from "./exporter.ts";
import { AbortError } from "../abort-error.ts";

/** Create a fake ChildProcess that resolves/rejects after a delay. */
function fakeProcess(
  delayMs: number,
  code = 0,
): Deno.ChildProcess {
  let killed = false;
  // deno-lint-ignore no-explicit-any
  const fake: any = {
    output(): Promise<Deno.CommandOutput> {
      return new Promise((resolve, reject) => {
        const id = setTimeout(() => {
          if (killed) {
            resolve({
              code: 137,
              signal: "SIGTERM",
              success: false,
              stdout: new Uint8Array(),
              stderr: new Uint8Array(),
            });
          } else {
            resolve({
              code,
              signal: null,
              success: code === 0,
              stdout: new Uint8Array(),
              stderr: new Uint8Array(),
            });
          }
        }, delayMs);
        // Store for cleanup
        fake._timerId = id;
        fake._reject = reject;
      });
    },
    kill(_signal: string) {
      killed = true;
      // Resolve the output promise quickly after kill
      if (fake._timerId) {
        clearTimeout(fake._timerId);
        // The process.output() will resolve on next tick with killed state
      }
    },
    pid: 999,
    status: Promise.resolve({ code, signal: null, success: code === 0 }),
    stdin: null,
    stdout: null,
    stderr: null,
    ref() {},
    unref() {},
    [Symbol.dispose]() {},
  };
  return fake as Deno.ChildProcess;
}

Deno.test("raceSubprocess: returns output when subprocess completes before timeout", async () => {
  const process = fakeProcess(10);
  const result = await raceSubprocess(process, 5000);
  assertEquals(result.code, 0);
});

Deno.test("raceSubprocess: rejects on timeout with LadderTimeoutError", async () => {
  const process = fakeProcess(5000);
  await assertRejects(
    () => raceSubprocess(process, 50),
    LadderTimeoutError,
  );
});

Deno.test("raceSubprocess: rejects on abort signal", async () => {
  const controller = new AbortController();
  const process = fakeProcess(5000);

  setTimeout(() => controller.abort(), 20);

  await assertRejects(
    () => raceSubprocess(process, 30000, controller.signal),
    AbortError,
  );
});

Deno.test("raceSubprocess: rejects immediately if signal already aborted", async () => {
  const controller = new AbortController();
  controller.abort();

  const process = fakeProcess(10);
  await assertRejects(
    () => raceSubprocess(process, 5000, controller.signal),
    Error,
  );
});

Deno.test("raceSubprocess: cleans up timer on normal completion", async () => {
  // If the timer leaked without cleanup, the test sanitizer would flag it.
  // The unrefTimer prevents blocking, and the finally block clears it.
  const process = fakeProcess(10);
  const result = await raceSubprocess(process, 60000);
  assertEquals(result.code, 0);
});
