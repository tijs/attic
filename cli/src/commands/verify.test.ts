import { assertEquals } from "@std/assert";
import { runVerify } from "./verify.ts";
import type { Manifest } from "../manifest/manifest.ts";
import { createMockS3Provider } from "../storage/s3-client.mock.ts";

function makeManifest(
  entries: Record<string, { s3Key: string; checksum: string }>,
): Manifest {
  const manifest: Manifest = { entries: {} };
  for (const [uuid, { s3Key, checksum }] of Object.entries(entries)) {
    manifest.entries[uuid] = {
      uuid,
      s3Key,
      checksum,
      backedUpAt: "2024-01-15T00:00:00Z",
    };
  }
  return manifest;
}

Deno.test("verify quick: all objects present", async () => {
  const s3 = createMockS3Provider();
  const data = new TextEncoder().encode("photo-data");
  await s3.putObject("originals/2024/01/uuid-1.heic", data);
  await s3.putObject("originals/2024/01/uuid-2.heic", data);

  const manifest = makeManifest({
    "uuid-1": {
      s3Key: "originals/2024/01/uuid-1.heic",
      checksum: "sha256:abc",
    },
    "uuid-2": {
      s3Key: "originals/2024/01/uuid-2.heic",
      checksum: "sha256:def",
    },
  });

  const report = await runVerify(manifest, s3, { concurrency: 1 });

  assertEquals(report.total, 2);
  assertEquals(report.ok, 2);
  assertEquals(report.missing, 0);
  assertEquals(report.corrupted, 0);
  assertEquals(report.errors.length, 0);
});

Deno.test("verify quick: detects missing objects", async () => {
  const s3 = createMockS3Provider();
  await s3.putObject(
    "originals/2024/01/uuid-1.heic",
    new TextEncoder().encode("data"),
  );

  const manifest = makeManifest({
    "uuid-1": {
      s3Key: "originals/2024/01/uuid-1.heic",
      checksum: "sha256:abc",
    },
    "uuid-2": {
      s3Key: "originals/2024/01/uuid-2.heic",
      checksum: "sha256:def",
    },
  });

  const report = await runVerify(manifest, s3, { concurrency: 1 });

  assertEquals(report.total, 2);
  assertEquals(report.ok, 1);
  assertEquals(report.missing, 1);
  assertEquals(report.errors.length, 1);
  assertEquals(report.errors[0].uuid, "uuid-2");
});

Deno.test("verify deep: checksum match passes", async () => {
  const s3 = createMockS3Provider();
  const data = new TextEncoder().encode("hello");

  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  const hashHex = Array.from(
    new Uint8Array(hashBuffer),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");

  await s3.putObject("originals/2024/01/uuid-1.heic", data);

  const manifest = makeManifest({
    "uuid-1": {
      s3Key: "originals/2024/01/uuid-1.heic",
      checksum: `sha256:${hashHex}`,
    },
  });

  const report = await runVerify(manifest, s3, {
    deep: true,
    concurrency: 1,
  });

  assertEquals(report.total, 1);
  assertEquals(report.ok, 1);
  assertEquals(report.corrupted, 0);
});

Deno.test("verify deep: checksum mismatch detected", async () => {
  const s3 = createMockS3Provider();
  await s3.putObject(
    "originals/2024/01/uuid-1.heic",
    new TextEncoder().encode("actual-data"),
  );

  const manifest = makeManifest({
    "uuid-1": {
      s3Key: "originals/2024/01/uuid-1.heic",
      checksum:
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    },
  });

  const report = await runVerify(manifest, s3, {
    deep: true,
    concurrency: 1,
  });

  assertEquals(report.total, 1);
  assertEquals(report.ok, 0);
  assertEquals(report.corrupted, 1);
  assertEquals(report.errors.length, 1);
  assertEquals(report.errors[0].uuid, "uuid-1");
});

Deno.test("verify: empty manifest reports nothing to verify", async () => {
  const s3 = createMockS3Provider();
  const manifest: Manifest = { entries: {} };

  const report = await runVerify(manifest, s3);

  assertEquals(report.total, 0);
  assertEquals(report.ok, 0);
});

Deno.test("verify: concurrent verification produces correct counts", async () => {
  const s3 = createMockS3Provider();

  // Create 10 objects, leave 3 missing
  for (let i = 0; i < 7; i++) {
    await s3.putObject(
      `originals/2024/01/uuid-${i}.heic`,
      new TextEncoder().encode(`data-${i}`),
    );
  }

  const entries: Record<string, { s3Key: string; checksum: string }> = {};
  for (let i = 0; i < 10; i++) {
    entries[`uuid-${i}`] = {
      s3Key: `originals/2024/01/uuid-${i}.heic`,
      checksum: "sha256:abc",
    };
  }

  const manifest = makeManifest(entries);
  const report = await runVerify(manifest, s3, { concurrency: 5 });

  assertEquals(report.total, 10);
  assertEquals(report.ok, 7);
  assertEquals(report.missing, 3);
  assertEquals(report.errors.length, 3);
});
