import { assertEquals } from "@std/assert";
import { createManifestStore, isBackedUp, markBackedUp } from "./manifest.ts";

Deno.test("load returns empty manifest when file missing", async () => {
  const dir = await Deno.makeTempDir();
  try {
    const store = createManifestStore(dir);
    const manifest = await store.load();
    assertEquals(manifest.entries, {});
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("save and load round-trip", async () => {
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

Deno.test("load rejects invalid manifest JSON", async () => {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.writeTextFile(`${dir}/manifest.json`, '{"bad": true}');
    const store = createManifestStore(dir);
    let threw = false;
    try {
      await store.load();
    } catch (e) {
      threw = true;
      assertEquals(
        (e as Error).message,
        "Invalid manifest file: missing or invalid 'entries'",
      );
    }
    assertEquals(threw, true);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});
