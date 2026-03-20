import { assertEquals } from "@std/assert";
import { rebuildManifest } from "./rebuild.ts";
import { createS3ManifestStore, isBackedUp } from "../manifest/manifest.ts";
import { createMockS3Provider } from "../storage/s3-client.mock.ts";

Deno.test("rebuildManifest: reconstructs from S3 metadata", async () => {
  const s3 = createMockS3Provider();

  const meta1 = {
    uuid: "uuid-1",
    s3Key: "originals/2024/01/uuid-1.heic",
    checksum:
      "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    backedUpAt: "2024-01-15T10:00:00Z",
  };
  const meta2 = {
    uuid: "uuid-2",
    s3Key: "originals/2024/02/uuid-2.jpg",
    checksum:
      "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    backedUpAt: "2024-02-20T14:00:00Z",
  };

  await s3.putObject(
    "metadata/assets/uuid-1.json",
    new TextEncoder().encode(JSON.stringify(meta1)),
    "application/json",
  );
  await s3.putObject(
    "metadata/assets/uuid-2.json",
    new TextEncoder().encode(JSON.stringify(meta2)),
    "application/json",
  );

  const manifestStore = createS3ManifestStore(s3);
  const rebuilt = await rebuildManifest(s3, manifestStore);

  assertEquals(isBackedUp(rebuilt, "uuid-1"), true);
  assertEquals(isBackedUp(rebuilt, "uuid-2"), true);
  assertEquals(
    rebuilt.entries["uuid-1"].s3Key,
    "originals/2024/01/uuid-1.heic",
  );
  assertEquals(
    rebuilt.entries["uuid-1"].checksum,
    "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  );
  assertEquals(rebuilt.entries["uuid-1"].backedUpAt, "2024-01-15T10:00:00Z");
  assertEquals(rebuilt.entries["uuid-2"].backedUpAt, "2024-02-20T14:00:00Z");

  // Verify it was saved to S3
  const loaded = await manifestStore.load();
  assertEquals(isBackedUp(loaded, "uuid-1"), true);
  assertEquals(isBackedUp(loaded, "uuid-2"), true);
});

Deno.test("rebuildManifest: skips invalid metadata files", async () => {
  const s3 = createMockS3Provider();

  // Valid metadata
  await s3.putObject(
    "metadata/assets/uuid-1.json",
    new TextEncoder().encode(
      JSON.stringify({
        uuid: "uuid-1",
        s3Key: "originals/2024/01/uuid-1.heic",
        checksum:
          "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      }),
    ),
    "application/json",
  );

  // Invalid metadata (missing required fields)
  await s3.putObject(
    "metadata/assets/bad.json",
    new TextEncoder().encode('{"foo": "bar"}'),
    "application/json",
  );

  // Not JSON at all
  await s3.putObject(
    "metadata/assets/garbage.json",
    new TextEncoder().encode("not json {{{"),
    "application/json",
  );

  const manifestStore = createS3ManifestStore(s3);
  const rebuilt = await rebuildManifest(s3, manifestStore);

  assertEquals(Object.keys(rebuilt.entries).length, 1);
  assertEquals(isBackedUp(rebuilt, "uuid-1"), true);
});

Deno.test("rebuildManifest: rejects path-traversal s3Keys", async () => {
  const s3 = createMockS3Provider();

  // s3Key with path traversal
  await s3.putObject(
    "metadata/assets/evil.json",
    new TextEncoder().encode(
      JSON.stringify({
        uuid: "uuid-evil",
        s3Key: "../../etc/passwd",
        checksum:
          "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      }),
    ),
    "application/json",
  );

  // Invalid checksum format
  await s3.putObject(
    "metadata/assets/bad-checksum.json",
    new TextEncoder().encode(
      JSON.stringify({
        uuid: "uuid-bad",
        s3Key: "originals/2024/01/uuid-bad.heic",
        checksum: "md5:abc123",
      }),
    ),
    "application/json",
  );

  const manifestStore = createS3ManifestStore(s3);
  const rebuilt = await rebuildManifest(s3, manifestStore);

  // Neither should be accepted
  assertEquals(Object.keys(rebuilt.entries).length, 0);
});
