import { assertEquals, assertRejects } from "@std/assert";
import type { Manifest } from "./manifest.ts";
import {
  createManifestStore,
  createS3ManifestStore,
  isBackedUp,
  loadManifestWithMigration,
  markBackedUp,
} from "./manifest.ts";
import { createMockS3Provider } from "../storage/s3-client.mock.ts";

// --- Local manifest store (legacy, kept for migration) ---

Deno.test("local store: load returns empty manifest when file missing", async () => {
  const dir = await Deno.makeTempDir();
  try {
    const store = createManifestStore(dir);
    const manifest = await store.load();
    assertEquals(manifest.entries, {});
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("local store: save and load round-trip", async () => {
  const dir = await Deno.makeTempDir();
  try {
    const store = createManifestStore(dir);
    const manifest = await store.load();
    markBackedUp(
      manifest,
      "uuid-1",
      "sha256:abc",
      "originals/2024/01/uuid-1.heic",
    );
    await store.save(manifest);

    const loaded = await store.load();
    assertEquals(
      loaded.entries["uuid-1"].s3Key,
      "originals/2024/01/uuid-1.heic",
    );
    assertEquals(loaded.entries["uuid-1"].checksum, "sha256:abc");
    assertEquals(loaded.entries["uuid-1"].uuid, "uuid-1");
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("isBackedUp checks correctly", async () => {
  const dir = await Deno.makeTempDir();
  try {
    const store = createManifestStore(dir);
    const manifest = await store.load();

    assertEquals(isBackedUp(manifest, "uuid-1"), false);

    markBackedUp(
      manifest,
      "uuid-1",
      "sha256:abc",
      "originals/2024/01/uuid-1.heic",
    );

    assertEquals(isBackedUp(manifest, "uuid-1"), true);
    assertEquals(isBackedUp(manifest, "uuid-2"), false);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("local store: load rejects invalid manifest JSON", async () => {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.writeTextFile(`${dir}/manifest.json`, '{"bad": true}');
    const store = createManifestStore(dir);
    await assertRejects(
      () => store.load(),
      Error,
      "missing or invalid 'entries'",
    );
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
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
    // Create a local manifest
    const localStore = createManifestStore(dir);
    const localManifest = { entries: {} } as Manifest;
    markBackedUp(
      localManifest,
      "local-uuid",
      "sha256:local",
      "originals/2024/01/local.heic",
    );
    await localStore.save(localManifest);

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
