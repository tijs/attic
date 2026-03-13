import type { Manifest, ManifestEntry } from "../manifest/manifest.ts";
import type { S3Provider } from "../storage/s3-client.ts";

export interface VerifyOptions {
  /** Download each object and re-checksum (slow but thorough). */
  deep: boolean;
  /** Max concurrent S3 requests. */
  concurrency: number;
}

const DEFAULT_OPTIONS: VerifyOptions = {
  deep: false,
  concurrency: 50,
};

const MAX_ERRORS = 1000;

export interface VerifyReport {
  total: number;
  ok: number;
  missing: number;
  corrupted: number;
  errors: Array<{ uuid: string; message: string }>;
  errorsOverflow: number;
}

/** Verify backup integrity by checking S3 objects against the manifest. */
export async function runVerify(
  manifest: Manifest,
  s3: S3Provider,
  opts: Partial<VerifyOptions> = {},
): Promise<VerifyReport> {
  const options = { ...DEFAULT_OPTIONS, ...opts };
  const entries = Object.values(manifest.entries);

  if (entries.length === 0) {
    console.log("\n  Nothing to verify — manifest is empty.\n");
    return {
      total: 0,
      ok: 0,
      missing: 0,
      corrupted: 0,
      errors: [],
      errorsOverflow: 0,
    };
  }

  console.log(`\n  Attic — Verify`);
  console.log(`  ══════════════\n`);
  console.log(`  Manifest entries:  ${entries.length.toLocaleString()}`);
  console.log(
    `  Mode:              ${options.deep ? "deep (checksum)" : "quick (HEAD)"}`,
  );
  console.log(`  Concurrency:       ${options.concurrency}`);
  console.log();

  const report: VerifyReport = {
    total: entries.length,
    ok: 0,
    missing: 0,
    corrupted: 0,
    errors: [],
    errorsOverflow: 0,
  };

  // Bounded concurrency pool
  let cursor = 0;
  let completed = 0;

  function recordResult(entry: ManifestEntry, result: VerifyResult): void {
    switch (result.status) {
      case "ok":
        report.ok++;
        break;
      case "missing":
        report.missing++;
        pushError(report, entry.uuid, `Missing from S3: ${entry.s3Key}`);
        break;
      case "corrupted":
        report.corrupted++;
        pushError(report, entry.uuid, result.message);
        break;
      case "error":
        pushError(report, entry.uuid, result.message);
        break;
    }
    completed++;
  }

  async function worker(): Promise<void> {
    while (cursor < entries.length) {
      const i = cursor++;
      const entry = entries[i];
      const result = options.deep
        ? await verifyDeep(entry, s3)
        : await verifyQuick(entry, s3);
      recordResult(entry, result);

      // Progress every 100 completions
      if (completed % 100 === 0 || completed === entries.length) {
        const pct = ((completed / entries.length) * 100).toFixed(1);
        console.log(
          `  Checked ${completed}/${entries.length} (${pct}%)  ` +
            `OK: ${report.ok}  Missing: ${report.missing}  Corrupted: ${report.corrupted}`,
        );
      }
    }
  }

  const workerCount = Math.min(options.concurrency, entries.length);
  await Promise.all(Array.from({ length: workerCount }, () => worker()));

  // Summary
  console.log(`\n  ── Verify Complete ──`);
  console.log(`  Total:      ${report.total.toLocaleString()}`);
  console.log(`  OK:         ${report.ok.toLocaleString()}`);
  console.log(`  Missing:    ${report.missing.toLocaleString()}`);
  console.log(`  Corrupted:  ${report.corrupted.toLocaleString()}`);
  if (report.errorsOverflow > 0) {
    console.log(
      `  (${report.errorsOverflow.toLocaleString()} additional errors not shown)`,
    );
  }
  console.log();

  return report;
}

function pushError(
  report: VerifyReport,
  uuid: string,
  message: string,
): void {
  if (report.errors.length < MAX_ERRORS) {
    report.errors.push({ uuid, message });
  } else {
    report.errorsOverflow++;
  }
}

interface VerifyResult {
  status: "ok" | "missing" | "corrupted" | "error";
  message: string;
}

/** Quick verify: HEAD the S3 object, confirm it exists. */
async function verifyQuick(
  entry: ManifestEntry,
  s3: S3Provider,
): Promise<VerifyResult> {
  try {
    const meta = await s3.headObject(entry.s3Key);
    if (!meta) {
      return { status: "missing", message: `Not found: ${entry.s3Key}` };
    }
    return { status: "ok", message: "" };
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : "Unknown error";
    return { status: "error", message: msg };
  }
}

/** Deep verify: download the S3 object, compute SHA-256, compare to manifest checksum. */
async function verifyDeep(
  entry: ManifestEntry,
  s3: S3Provider,
): Promise<VerifyResult> {
  try {
    let data: Uint8Array;
    try {
      data = await s3.getObject(entry.s3Key);
    } catch (error: unknown) {
      if (
        error instanceof Error && error.message.includes("not found") ||
        error instanceof Error && error.message.includes("Not found") ||
        error instanceof Error && error.message.includes("NoSuchKey")
      ) {
        return { status: "missing", message: `Not found: ${entry.s3Key}` };
      }
      throw error;
    }

    const hashBuffer = await crypto.subtle.digest(
      "SHA-256",
      data.buffer as ArrayBuffer,
    );
    const hashHex = Array.from(
      new Uint8Array(hashBuffer),
      (b) => b.toString(16).padStart(2, "0"),
    ).join("");
    const actual = `sha256:${hashHex}`;

    if (actual !== entry.checksum) {
      return {
        status: "corrupted",
        message:
          `Checksum mismatch for ${entry.s3Key}: expected ${entry.checksum}, got ${actual}`,
      };
    }

    return { status: "ok", message: "" };
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : "Unknown error";
    return { status: "error", message: msg };
  }
}
