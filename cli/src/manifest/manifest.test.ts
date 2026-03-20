import { assertEquals, assertRejects } from "@std/assert";
import type { Manifest } from "./manifest.ts";
import {
  createS3ManifestStore,
  isBackedUp,
  loadManifestWithMigration,
  markBackedUp,
} from "./manifest.ts";
import { createMockS3Provider } from "../storage/s3-client.mock.ts";

// --- Core functions ---

Deno.test("isBackedUp checks correctly", () => {
  const manifest: Manifest = { entries: {} };

  assertEquals(isBackedUp(manifest, "uuid-1"), false);

  markBackedUp(
    manifest,
    "uuid-1",
    "sha256:abc",
    "originals/2024/01/uuid-1.heic",
  );

  assertEquals(isBackedUp(manifest, "uuid-1"), true);
  assertEquals(isBackedUp(manifest, "uuid-2"), false);
});

// --- S3 manifest store ---

Deno.test("S3 store: load returns empty manifest when key missing", async () => {
  const s3 = createMockS3Provider();
  const store = createS3ManifestStore(s3);
  const manifest = await store.load();
  assertEquals(manifest.entries, {});
});

Deno.test("S3 store: save and load round-trip", async () => {
  const s3 = createMockS3Provider();
  const store = createS3ManifestStore(s3);
  const manifest = { entries: {} } as Manifest;
  markBackedUp(
    manifest,
    "uuid-1",
    "sha256:abc",
    "originals/2024/01/uuid-1.heic",
  );
  await store.save(manifest);

  const loaded = await store.load();
  assertEquals(isBackedUp(loaded, "uuid-1"), true);
  assertEquals(
    loaded.entries["uuid-1"].s3Key,
    "originals/2024/01/uuid-1.heic",
  );
});

Deno.test("S3 store: load rejects invalid JSON", async () => {
  const s3 = createMockS3Provider();
  await s3.putObject(
    "manifest.json",
    new TextEncoder().encode('{"bad": true}'),
  );
  const store = createS3ManifestStore(s3);
  await assertRejects(
    () => store.load(),
    Error,
    "missing or invalid 'entries'",
  );
});

Deno.test("S3 store: saves with correct content type", async () => {
  const s3 = createMockS3Provider();
  const store = createS3ManifestStore(s3);
  await store.save({ entries: {} });

  const obj = s3.objects.get("manifest.json");
  assertEquals(obj?.contentType, "application/json");
});

// --- Migration ---

Deno.test("migration: uses S3 manifest when present", async () => {
  const s3 = createMockS3Provider();
  const store = createS3ManifestStore(s3);
  const existing = { entries: {} } as Manifest;
  markBackedUp(existing, "s3-uuid", "sha256:s3", "originals/2024/01/s3.heic");
  await store.save(existing);

  const manifest = await loadManifestWithMigration(store, "/nonexistent");
  assertEquals(isBackedUp(manifest, "s3-uuid"), true);
});

Deno.test("migration: migrates local manifest to S3", async () => {
  const dir = await Deno.makeTempDir();
  try {
    // Write a local manifest file directly
    const localManifest = {
      entries: {
        "local-uuid": {
          uuid: "local-uuid",
          s3Key: "originals/2024/01/local.heic",
          checksum: "sha256:local",
          backedUpAt: "2024-01-15T00:00:00Z",
        },
      },
    };
    await Deno.writeTextFile(
      `${dir}/manifest.json`,
      JSON.stringify(localManifest, null, 2),
    );

    // S3 is empty
    const s3 = createMockS3Provider();
    const s3Store = createS3ManifestStore(s3);

    const manifest = await loadManifestWithMigration(s3Store, dir);
    assertEquals(isBackedUp(manifest, "local-uuid"), true);

    // Verify it was uploaded to S3
    const s3Manifest = await s3Store.load();
    assertEquals(isBackedUp(s3Manifest, "local-uuid"), true);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("migration: returns empty when neither exists", async () => {
  const s3 = createMockS3Provider();
  const store = createS3ManifestStore(s3);
  const manifest = await loadManifestWithMigration(store, "/nonexistent");
  assertEquals(Object.keys(manifest.entries).length, 0);
});

Deno.test("migration: S3 takes precedence over local", async () => {
  const dir = await Deno.makeTempDir();
  try {
    // Local manifest has one entry
    const localManifest = {
      entries: {
        "local-uuid": {
          uuid: "local-uuid",
          s3Key: "originals/2024/01/local.heic",
          checksum: "sha256:local",
          backedUpAt: "2024-01-15T00:00:00Z",
        },
      },
    };
    await Deno.writeTextFile(
      `${dir}/manifest.json`,
      JSON.stringify(localManifest, null, 2),
    );

    // S3 has a different entry
    const s3 = createMockS3Provider();
    const s3Store = createS3ManifestStore(s3);
    const s3Manifest = { entries: {} } as Manifest;
    markBackedUp(
      s3Manifest,
      "s3-uuid",
      "sha256:s3",
      "originals/2024/01/s3.heic",
    );
    await s3Store.save(s3Manifest);

    // S3 should win — local is not consulted
    const manifest = await loadManifestWithMigration(s3Store, dir);
    assertEquals(isBackedUp(manifest, "s3-uuid"), true);
    assertEquals(isBackedUp(manifest, "local-uuid"), false);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});
