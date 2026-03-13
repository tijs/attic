import { Command } from "@cliffy/command";
import { requireConfig } from "./src/config/config.ts";

const main = new Command()
  .name("attic")
  .version("0.1.0")
  .description("Back up your iCloud Photos library to S3-compatible storage")
  .action(function (this: Command) {
    this.showHelp();
  });

main.command("scan", "Scan Photos library and show statistics")
  .option("--db <path:string>", "Path to Photos.sqlite")
  .action(async ({ db }: { db?: string }) => {
    const { openPhotosDb } = await import("./src/photos-db/reader.ts");
    const { printScanReport } = await import("./src/commands/scan.ts");

    const reader = openPhotosDb(db);
    try {
      const assets = reader.readAssets();
      printScanReport(assets);
    } finally {
      reader.close();
    }
  });

main.command("status", "Compare Photos DB vs backup manifest")
  .option("--db <path:string>", "Path to Photos.sqlite")
  .action(async ({ db }: { db?: string }) => {
    const { openPhotosDb } = await import("./src/photos-db/reader.ts");
    const { printStatusReport } = await import("./src/commands/status.ts");
    const { createManifestStore } = await import("./src/manifest/manifest.ts");

    const reader = openPhotosDb(db);
    try {
      const assets = reader.readAssets();
      const manifestStore = createManifestStore();
      await printStatusReport(assets, manifestStore);
    } finally {
      reader.close();
    }
  });

main.command("backup", "Back up pending assets to S3")
  .option("--dry-run", "Show what would be uploaded")
  .option("--limit <n:integer>", "Back up at most N assets")
  .option("--batch-size <n:integer>", "Assets per ladder batch", {
    default: 50,
  })
  .option("--type <type:string>", "Only back up photos or videos")
  .option("--bucket <name:string>", "Override bucket from config")
  .option("--ladder <path:string>", "Path to ladder binary")
  .option("--db <path:string>", "Path to Photos.sqlite")
  .action(async (options: {
    dryRun?: boolean;
    limit?: number;
    batchSize: number;
    type?: string;
    bucket?: string;
    ladder?: string;
    db?: string;
  }) => {
    const { openPhotosDb } = await import("./src/photos-db/reader.ts");
    const { runBackup } = await import("./src/commands/backup.ts");
    const { createManifestStore } = await import("./src/manifest/manifest.ts");
    const { createS3Provider, loadKeychainCredentials } = await import(
      "./src/storage/s3-client.ts"
    );
    const { createLadderExporter } = await import("./src/export/exporter.ts");

    const config = requireConfig();
    const reader = openPhotosDb(options.db);
    try {
      const assets = reader.readAssets();
      const manifestStore = createManifestStore();
      const manifest = await manifestStore.load();

      const credentials = await loadKeychainCredentials(
        config.keychain.accessKeyService,
        config.keychain.secretKeyService,
      );
      const s3 = createS3Provider(
        credentials,
        options.bucket ?? config.bucket,
        {
          endpoint: config.endpoint,
          region: config.region,
          pathStyle: config.pathStyle,
        },
      );

      const ladderPath = options.ladder ??
        Deno.env.get("LADDER_PATH") ??
        "ladder";
      const exporter = createLadderExporter(ladderPath);

      const typeFilter = options.type as "photo" | "video" | undefined;

      await runBackup(assets, manifest, manifestStore, exporter, s3, {
        batchSize: options.batchSize,
        limit: options.limit ?? 0,
        type: typeFilter ?? null,
        dryRun: options.dryRun ?? false,
      });
    } finally {
      reader.close();
    }
  });

main.command("verify", "Verify backup integrity against S3")
  .option("--deep", "Download and re-checksum each object")
  .option("--rebuild-manifest", "Reconstruct manifest from S3 metadata")
  .option("--bucket <name:string>", "Override bucket from config")
  .action(async (options: {
    deep?: boolean;
    rebuildManifest?: boolean;
    bucket?: string;
  }) => {
    const { runVerify } = await import("./src/commands/verify.ts");
    const { rebuildManifest } = await import("./src/commands/rebuild.ts");
    const { createManifestStore } = await import("./src/manifest/manifest.ts");
    const { createS3Provider, loadKeychainCredentials } = await import(
      "./src/storage/s3-client.ts"
    );

    const config = requireConfig();

    const credentials = await loadKeychainCredentials(
      config.keychain.accessKeyService,
      config.keychain.secretKeyService,
    );
    const s3 = createS3Provider(
      credentials,
      options.bucket ?? config.bucket,
      {
        endpoint: config.endpoint,
        region: config.region,
        pathStyle: config.pathStyle,
      },
    );
    const manifestStore = createManifestStore();

    if (options.rebuildManifest) {
      await rebuildManifest(s3, manifestStore);
    } else {
      const manifest = await manifestStore.load();
      await runVerify(manifest, s3, {
        deep: options.deep ?? false,
      });
    }
  });

await main.parse(Deno.args);
