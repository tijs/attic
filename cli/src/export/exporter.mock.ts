import { join } from "@std/path/join";
import type { ExportBatchResult, ExportedAsset, Exporter } from "./exporter.ts";

/** In-memory mock exporter for testing. */
export function createMockExporter(
  knownAssets: Map<string, { filename: string; data: Uint8Array }>,
  stagingDir: string,
): Exporter & { stagingDir: string } {
  return {
    stagingDir,

    async exportBatch(uuids: string[]): Promise<ExportBatchResult> {
      await Deno.mkdir(stagingDir, { recursive: true });

      const results: ExportedAsset[] = [];
      const errors: ExportBatchResult["errors"] = [];

      for (const uuid of uuids) {
        const asset = knownAssets.get(uuid);
        if (!asset) {
          errors.push({ uuid, message: "Asset not found in Photos library" });
          continue;
        }

        const path = join(stagingDir, `${uuid}_${asset.filename}`);
        await Deno.writeFile(path, asset.data);

        // Deterministic hash for testing (hex of byte values, zero-padded to 64 chars)
        const hex = Array.from(
          asset.data,
          (b) => b.toString(16).padStart(2, "0"),
        )
          .join("");
        const hash = hex.padEnd(64, "0").slice(0, 64);

        results.push({
          uuid,
          path,
          size: asset.data.length,
          sha256: hash,
        });
      }

      return { results, errors };
    },
  };
}
