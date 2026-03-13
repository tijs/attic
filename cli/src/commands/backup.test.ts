import { assertEquals } from "@std/assert";
import type { PhotoAsset } from "@attic/shared";
import { AssetKind, CloudLocalState } from "@attic/shared";
import { runBackup } from "./backup.ts";
import { createManifestStore, isBackedUp } from "../manifest/manifest.ts";
import { createMockExporter } from "../export/exporter.mock.ts";
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
    ...overrides,
  };
}

Deno.test("backup: uploads pending assets and updates manifest", async () => {
  const tmpDir = await Deno.makeTempDir();
  const stagingDir = `${tmpDir}/staging`;
  const manifestDir = `${tmpDir}/manifest`;
  try {
    const assets = [makeAsset("uuid-1"), makeAsset("uuid-2")];

    const mockAssets = new Map([
      [
        "uuid-1",
        { filename: "IMG_0001.HEIC", data: new TextEncoder().encode("photo1") },
      ],
      [
        "uuid-2",
        { filename: "IMG_0002.HEIC", data: new TextEncoder().encode("photo2") },
      ],
    ]);

    const exporter = createMockExporter(mockAssets, stagingDir);
    const s3 = createMockS3Provider();
    const manifestStore = createManifestStore(manifestDir);
    const manifest = await manifestStore.load();

    const report = await runBackup(
      assets,
      manifest,
      manifestStore,
      exporter,
      s3,
      { batchSize: 10 },
      stagingDir,
    );

    assertEquals(report.uploaded, 2);
    assertEquals(report.failed, 0);
    assertEquals(report.errors.length, 0);

    // Manifest should have both entries
    assertEquals(isBackedUp(manifest, "uuid-1"), true);
    assertEquals(isBackedUp(manifest, "uuid-2"), true);

    // S3 should have originals + metadata
    assertEquals(s3.objects.size, 4); // 2 originals + 2 metadata
  } finally {
    await Deno.remove(tmpDir, { recursive: true });
  }
});

Deno.test("backup: skips already backed-up assets", async () => {
  const tmpDir = await Deno.makeTempDir();
  const stagingDir = `${tmpDir}/staging`;
  const manifestDir = `${tmpDir}/manifest`;
  try {
    const assets = [makeAsset("uuid-1"), makeAsset("uuid-2")];

    const mockAssets = new Map([
      [
        "uuid-2",
        { filename: "IMG_0002.HEIC", data: new TextEncoder().encode("photo2") },
      ],
    ]);

    const exporter = createMockExporter(mockAssets, stagingDir);
    const s3 = createMockS3Provider();
    const manifestStore = createManifestStore(manifestDir);
    const manifest = await manifestStore.load();

    // Pre-mark uuid-1 as backed up
    manifest.entries["uuid-1"] = {
      uuid: "uuid-1",
      s3Key: "originals/2024/01/uuid-1.heic",
      checksum: "sha256:abc",
      backedUpAt: "2024-01-15T00:00:00Z",
    };

    const report = await runBackup(
      assets,
      manifest,
      manifestStore,
      exporter,
      s3,
      { batchSize: 10 },
      stagingDir,
    );

    assertEquals(report.uploaded, 1);
    assertEquals(report.failed, 0);

    // Only uuid-2's files should be in S3
    assertEquals(s3.objects.size, 2); // 1 original + 1 metadata
  } finally {
    await Deno.remove(tmpDir, { recursive: true });
  }
});

Deno.test("backup: respects --limit flag", async () => {
  const tmpDir = await Deno.makeTempDir();
  const stagingDir = `${tmpDir}/staging`;
  const manifestDir = `${tmpDir}/manifest`;
  try {
    const assets = [
      makeAsset("uuid-1"),
      makeAsset("uuid-2"),
      makeAsset("uuid-3"),
    ];

    const mockAssets = new Map([
      [
        "uuid-1",
        { filename: "IMG_0001.HEIC", data: new TextEncoder().encode("p1") },
      ],
    ]);

    const exporter = createMockExporter(mockAssets, stagingDir);
    const s3 = createMockS3Provider();
    const manifestStore = createManifestStore(manifestDir);
    const manifest = await manifestStore.load();

    const report = await runBackup(
      assets,
      manifest,
      manifestStore,
      exporter,
      s3,
      { limit: 1, batchSize: 10 },
      stagingDir,
    );

    assertEquals(report.uploaded, 1);
  } finally {
    await Deno.remove(tmpDir, { recursive: true });
  }
});

Deno.test("backup: dry run skips uploads", async () => {
  const tmpDir = await Deno.makeTempDir();
  const manifestDir = `${tmpDir}/manifest`;
  try {
    const assets = [makeAsset("uuid-1")];

    const exporter = createMockExporter(new Map(), `${tmpDir}/staging`);
    const s3 = createMockS3Provider();
    const manifestStore = createManifestStore(manifestDir);
    const manifest = await manifestStore.load();

    const report = await runBackup(
      assets,
      manifest,
      manifestStore,
      exporter,
      s3,
      { dryRun: true },
      `${tmpDir}/staging`,
    );

    assertEquals(report.uploaded, 0);
    assertEquals(report.skipped, 1);
    assertEquals(s3.objects.size, 0);
    assertEquals(isBackedUp(manifest, "uuid-1"), false);
  } finally {
    await Deno.remove(tmpDir, { recursive: true });
  }
});

Deno.test("backup: handles export errors gracefully", async () => {
  const tmpDir = await Deno.makeTempDir();
  const stagingDir = `${tmpDir}/staging`;
  const manifestDir = `${tmpDir}/manifest`;
  try {
    const assets = [makeAsset("uuid-1"), makeAsset("uuid-missing")];

    // Only uuid-1 is known to the exporter
    const mockAssets = new Map([
      [
        "uuid-1",
        { filename: "IMG_0001.HEIC", data: new TextEncoder().encode("data") },
      ],
    ]);

    const exporter = createMockExporter(mockAssets, stagingDir);
    const s3 = createMockS3Provider();
    const manifestStore = createManifestStore(manifestDir);
    const manifest = await manifestStore.load();

    const report = await runBackup(
      assets,
      manifest,
      manifestStore,
      exporter,
      s3,
      { batchSize: 10 },
      stagingDir,
    );

    assertEquals(report.uploaded, 1);
    assertEquals(report.failed, 1);
    assertEquals(report.errors.length, 1);
    assertEquals(report.errors[0].uuid, "uuid-missing");
  } finally {
    await Deno.remove(tmpDir, { recursive: true });
  }
});

Deno.test("backup: filters by type", async () => {
  const tmpDir = await Deno.makeTempDir();
  const stagingDir = `${tmpDir}/staging`;
  const manifestDir = `${tmpDir}/manifest`;
  try {
    const assets = [
      makeAsset("photo-1", { kind: AssetKind.PHOTO }),
      makeAsset("video-1", {
        kind: AssetKind.VIDEO,
        uniformTypeIdentifier: "com.apple.quicktime-movie",
        filename: "VID.MOV",
        originalFilename: "VID.MOV",
      }),
    ];

    const mockAssets = new Map([
      [
        "video-1",
        { filename: "VID.MOV", data: new TextEncoder().encode("video") },
      ],
    ]);

    const exporter = createMockExporter(mockAssets, stagingDir);
    const s3 = createMockS3Provider();
    const manifestStore = createManifestStore(manifestDir);
    const manifest = await manifestStore.load();

    const report = await runBackup(
      assets,
      manifest,
      manifestStore,
      exporter,
      s3,
      { type: "video", batchSize: 10 },
      stagingDir,
    );

    assertEquals(report.uploaded, 1);
    assertEquals(isBackedUp(manifest, "video-1"), true);
    assertEquals(isBackedUp(manifest, "photo-1"), false);
  } finally {
    await Deno.remove(tmpDir, { recursive: true });
  }
});

Deno.test("backup: saves manifest to disk", async () => {
  const tmpDir = await Deno.makeTempDir();
  const stagingDir = `${tmpDir}/staging`;
  const manifestDir = `${tmpDir}/manifest`;
  try {
    const assets = [makeAsset("uuid-1")];

    const mockAssets = new Map([
      [
        "uuid-1",
        { filename: "IMG_0001.HEIC", data: new TextEncoder().encode("data") },
      ],
    ]);

    const exporter = createMockExporter(mockAssets, stagingDir);
    const s3 = createMockS3Provider();
    const manifestStore = createManifestStore(manifestDir);
    const manifest = await manifestStore.load();

    await runBackup(
      assets,
      manifest,
      manifestStore,
      exporter,
      s3,
      { batchSize: 10 },
      stagingDir,
    );

    // Load from disk — should persist
    const loaded = await manifestStore.load();
    assertEquals(isBackedUp(loaded, "uuid-1"), true);
  } finally {
    await Deno.remove(tmpDir, { recursive: true });
  }
});
