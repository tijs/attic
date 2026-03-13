import { assertEquals, assertExists } from "@std/assert";
import type { PhotoAsset } from "@attic/shared";
import { AssetKind, CloudLocalState } from "@attic/shared";
import { refreshMetadata } from "./refresh-metadata.ts";
import type { Manifest } from "../manifest/manifest.ts";
import { createMockS3Provider } from "../storage/s3-client.mock.ts";

function makeAsset(
  uuid: string,
  overrides: Partial<PhotoAsset> = {},
): PhotoAsset {
  return {
    uuid,
    filename: "IMG_0001.HEIC",
    originalFilename: "IMG_0001.HEIC",
    directory: "/some/dir",
    dateCreated: new Date("2024-01-15T12:00:00Z"),
    kind: AssetKind.PHOTO,
    uniformTypeIdentifier: "public.heic",
    width: 4032,
    height: 3024,
    latitude: 52.09,
    longitude: 4.34,
    favorite: false,
    cloudLocalState: CloudLocalState.LOCAL,
    originalFileSize: 3000,
    originalStableHash: "abc123",
    title: null,
    description: null,
    albums: [],
    keywords: [],
    people: [],
    hasEdit: false,
    editedAt: null,
    editor: null,
    ...overrides,
  };
}

function makeManifest(
  entries: Record<
    string,
    { s3Key: string; checksum: string; backedUpAt: string }
  >,
): Manifest {
  const manifest: Manifest = { entries: {} };
  for (const [uuid, e] of Object.entries(entries)) {
    manifest.entries[uuid] = { uuid, ...e };
  }
  return manifest;
}

Deno.test("refresh-metadata: updates metadata for backed-up assets", async () => {
  const assets = [
    makeAsset("uuid-1", {
      title: "Sunset",
      description: "Beautiful sunset",
      albums: [{ uuid: "album-1", title: "Vacation" }],
      keywords: ["nature"],
      people: [{ uuid: "person-1", displayName: "Alice" }],
    }),
    makeAsset("uuid-2"),
  ];

  const manifest = makeManifest({
    "uuid-1": {
      s3Key: "originals/2024/01/uuid-1.heic",
      checksum: "sha256:abc",
      backedUpAt: "2024-02-01T00:00:00Z",
    },
    "uuid-2": {
      s3Key: "originals/2024/01/uuid-2.heic",
      checksum: "sha256:def",
      backedUpAt: "2024-02-01T00:00:00Z",
    },
  });

  const s3 = createMockS3Provider();
  const report = await refreshMetadata(assets, manifest, s3);

  assertEquals(report.updated, 2);
  assertEquals(report.failed, 0);

  // Verify metadata was uploaded
  const meta1Obj = s3.objects.get("metadata/assets/uuid-1.json");
  assertExists(meta1Obj);
  const meta1 = JSON.parse(new TextDecoder().decode(meta1Obj.body));
  assertEquals(meta1.title, "Sunset");
  assertEquals(meta1.description, "Beautiful sunset");
  assertEquals(meta1.albums, [{ uuid: "album-1", title: "Vacation" }]);
  assertEquals(meta1.keywords, ["nature"]);
  assertEquals(meta1.people, [{ uuid: "person-1", displayName: "Alice" }]);
  assertEquals(meta1.s3Key, "originals/2024/01/uuid-1.heic");
  assertEquals(meta1.checksum, "sha256:abc");
  assertEquals(meta1.backedUpAt, "2024-02-01T00:00:00Z");

  // uuid-2 also updated with defaults
  const meta2Obj = s3.objects.get("metadata/assets/uuid-2.json");
  assertExists(meta2Obj);
  const meta2 = JSON.parse(new TextDecoder().decode(meta2Obj.body));
  assertEquals(meta2.title, null);
  assertEquals(meta2.albums, []);
});

Deno.test("refresh-metadata: skips assets not in manifest", async () => {
  const assets = [makeAsset("uuid-1"), makeAsset("uuid-not-backed-up")];

  const manifest = makeManifest({
    "uuid-1": {
      s3Key: "originals/2024/01/uuid-1.heic",
      checksum: "sha256:abc",
      backedUpAt: "2024-02-01T00:00:00Z",
    },
  });

  const s3 = createMockS3Provider();
  const report = await refreshMetadata(assets, manifest, s3);

  assertEquals(report.updated, 1);
  assertEquals(
    s3.objects.has("metadata/assets/uuid-not-backed-up.json"),
    false,
  );
});

Deno.test("refresh-metadata: dry run uploads nothing", async () => {
  const assets = [makeAsset("uuid-1")];

  const manifest = makeManifest({
    "uuid-1": {
      s3Key: "originals/2024/01/uuid-1.heic",
      checksum: "sha256:abc",
      backedUpAt: "2024-02-01T00:00:00Z",
    },
  });

  const s3 = createMockS3Provider();
  const report = await refreshMetadata(assets, manifest, s3, { dryRun: true });

  assertEquals(report.updated, 0);
  assertEquals(report.skipped, 1);
  assertEquals(s3.objects.size, 0);
});

Deno.test("refresh-metadata: records failures when S3 upload throws", async () => {
  const assets = [makeAsset("uuid-1")];

  const manifest = makeManifest({
    "uuid-1": {
      s3Key: "originals/2024/01/uuid-1.heic",
      checksum: "sha256:abc",
      backedUpAt: "2024-02-01T00:00:00Z",
    },
  });

  const s3 = createMockS3Provider();
  s3.putObject = () => {
    throw new Error("S3 unavailable");
  };

  const report = await refreshMetadata(assets, manifest, s3);

  assertEquals(report.updated, 0);
  assertEquals(report.failed, 1);
  assertEquals(report.errors.length, 1);
  assertEquals(report.errors[0].message, "S3 unavailable");
});
