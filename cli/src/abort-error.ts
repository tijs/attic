/** Custom error for abort-based interruptions (Ctrl+C, signal, etc). */
export class AbortError extends Error {
  constructor(message = "Operation aborted") {
    super(message);
    this.name = "AbortError";
  }
}
