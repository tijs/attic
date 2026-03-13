import { assertEquals, assertRejects } from "@std/assert";
import { createMockExporter } from "./exporter.mock.ts";
import { removeStagedFile } from "./exporter.ts";

Deno.test("mock exporter: exports known assets", async () => {
  const dir = await Deno.makeTempDir();
  try {
    const assets = new Map([
      ["uuid-1", { filename: "IMG_001.HEIC", data: new Uint8Array([1, 2, 3]) }],
    ]);
    const exporter = createMockExporter(assets, dir);
    const result = await exporter.exportBatch(["uuid-1"]);

    assertEquals(result.results.length, 1);
    assertEquals(result.errors.length, 0);
    assertEquals(result.results[0].uuid, "uuid-1");
    assertEquals(result.results[0].size, 3);

    // Verify file was written
    const data = await Deno.readFile(result.results[0].path);
    assertEquals(data, new Uint8Array([1, 2, 3]));
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("mock exporter: reports missing assets as errors", async () => {
  const dir = await Deno.makeTempDir();
  try {
    const exporter = createMockExporter(new Map(), dir);
    const result = await exporter.exportBatch(["missing-uuid"]);

    assertEquals(result.results.length, 0);
    assertEquals(result.errors.length, 1);
    assertEquals(result.errors[0].uuid, "missing-uuid");
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("removeStagedFile: cleans up file in staging dir", async () => {
  const dir = await Deno.makeTempDir();
  try {
    const path = `${dir}/testfile`;
    await Deno.writeTextFile(path, "data");

    await removeStagedFile(path, dir);

    let exists = true;
    try {
      await Deno.stat(path);
    } catch {
      exists = false;
    }
    assertEquals(exists, false);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("removeStagedFile: ignores missing file", async () => {
  const dir = await Deno.makeTempDir();
  try {
    // Should not throw
    await removeStagedFile(`${dir}/nonexistent`, dir);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("removeStagedFile: rejects path outside staging dir", async () => {
  const stagingDir = await Deno.makeTempDir();
  const outsideDir = await Deno.makeTempDir();
  const outsidePath = `${outsideDir}/secret`;
  await Deno.writeTextFile(outsidePath, "sensitive");
  try {
    await assertRejects(
      () => removeStagedFile(outsidePath, stagingDir),
      Error,
      "Refusing to delete file outside staging directory",
    );
    // File should still exist
    const data = await Deno.readTextFile(outsidePath);
    assertEquals(data, "sensitive");
  } finally {
    await Deno.remove(stagingDir, { recursive: true });
    await Deno.remove(outsideDir, { recursive: true });
  }
});
