/**
 * Structured JSONL logger for unattended backup runs.
 * Each line is a self-contained JSON object with an event type and timestamp.
 */

export interface BackupLogger {
  start(pending: number, photos: number, videos: number): void;
  uploaded(uuid: string, filename: string, type: string, size: number): void;
  error(uuid: string, message: string): void;
  complete(uploaded: number, failed: number, totalBytes: number): void;
  interrupted(uploaded: number, pending: number, totalBytes: number): void;
  close(): void;
}

function makeEntry(event: string, data: Record<string, unknown>): string {
  return JSON.stringify({ event, ...data, timestamp: new Date().toISOString() });
}

/** Create a logger that appends JSONL to the given file path. */
export function createFileLogger(path: string): BackupLogger {
  const file = Deno.openSync(path, { write: true, create: true, append: true });
  const encoder = new TextEncoder();

  const write = (line: string) => {
    file.writeSync(encoder.encode(line + "\n"));
  };

  return {
    start(pending, photos, videos) {
      write(makeEntry("start", { pending, photos, videos }));
    },
    uploaded(uuid, filename, type, size) {
      write(makeEntry("uploaded", { uuid, filename, type, size }));
    },
    error(uuid, message) {
      write(makeEntry("error", { uuid, message }));
    },
    complete(uploaded, failed, totalBytes) {
      write(makeEntry("complete", { uploaded, failed, totalBytes }));
    },
    interrupted(uploaded, pending, totalBytes) {
      write(makeEntry("interrupted", { uploaded, pending, totalBytes }));
    },
    close() {
      file.close();
    },
  };
}

/** No-op logger for when --log is not specified. */
export function createNullLogger(): BackupLogger {
  return {
    start() {},
    uploaded() {},
    error() {},
    complete() {},
    interrupted() {},
    close() {},
  };
}
