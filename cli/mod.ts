import { Command, EnumType } from "@cliffy/command";
import { type AtticConfig, requireConfig } from "./src/config/config.ts";
import type { S3ConnectionConfig } from "./src/storage/s3-client.ts";

const assetType = new EnumType(["photo", "video"]);

function s3ConnectionFromConfig(config: AtticConfig): S3ConnectionConfig {
  return {
    endpoint: config.endpoint,
    region: config.region,
    pathStyle: config.pathStyle,
  };
}

const main = new Command()
  .name("attic")
  .version("0.2.0")
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
  .option("--bucket <name:string>", "Override bucket from config")
  .action(async ({ db, bucket }: { db?: string; bucket?: string }) => {
    const { openPhotosDb } = await import("./src/photos-db/reader.ts");
    const { printStatusReport } = await import("./src/commands/status.ts");
    const { createS3ManifestStore } = await import(
      "./src/manifest/manifest.ts"
    );
    const { createS3Provider } = await import("./src/storage/s3-client.ts");
    const { loadKeychainCredentials } = await import(
      "./src/keychain/keychain.ts"
    );

    const config = requireConfig();
    const reader = openPhotosDb(db);
    try {
      const assets = reader.readAssets();
      const credentials = await loadKeychainCredentials(
        config.keychain.accessKeyService,
        config.keychain.secretKeyService,
      );
      const s3 = createS3Provider(
        credentials,
        bucket ?? config.bucket,
        s3ConnectionFromConfig(config),
      );
      const manifestStore = createS3ManifestStore(s3);
      const manifest = await manifestStore.load();
      printStatusReport(assets, manifest);
    } finally {
      reader.close();
    }
  });

main.command("backup", "Back up pending assets to S3")
  .option("--dry-run", "Show what would be uploaded")
  .option("--limit <n:integer>", "Stop after N assets (useful for test runs)")
  .option("--batch-size <n:integer>", "Assets per export batch", {
    default: 50,
  })
  .type("asset-type", assetType)
  .option("--type <type:asset-type>", "Only back up photos or videos")
  .option("--bucket <name:string>", "Override bucket from config")
  .option("--ladder <path:string>", "Path to ladder binary")
  .option("--db <path:string>", "Path to Photos.sqlite")
  .option("-q, --quiet", "Suppress progress output (for unattended use)")
  .option("--log <path:string>", "Append structured JSONL log to file")
  .option("--notify", "Send macOS notification on completion")
  .action(async (options: {
    dryRun?: boolean;
    limit?: number;
    batchSize: number;
    type?: "photo" | "video";
    bucket?: string;
    ladder?: string;
    db?: string;
    quiet?: boolean;
    log?: string;
    notify?: boolean;
  }) => {
    const { openPhotosDb } = await import("./src/photos-db/reader.ts");
    const { runBackup } = await import("./src/commands/backup.ts");
    const {
      createS3ManifestStore,
      loadManifestWithMigration,
    } = await import("./src/manifest/manifest.ts");
    const { createS3Provider } = await import("./src/storage/s3-client.ts");
    const { loadKeychainCredentials } = await import(
      "./src/keychain/keychain.ts"
    );
    const { createLadderExporter } = await import("./src/export/exporter.ts");
    const { createFileLogger, createNullLogger } = await import(
      "./src/logger.ts"
    );

    const config = requireConfig();
    const reader = openPhotosDb(options.db);
    const logger = options.log
      ? createFileLogger(options.log)
      : createNullLogger();
    try {
      const assets = reader.readAssets();

      const credentials = await loadKeychainCredentials(
        config.keychain.accessKeyService,
        config.keychain.secretKeyService,
      );
      const s3 = createS3Provider(
        credentials,
        options.bucket ?? config.bucket,
        s3ConnectionFromConfig(config),
      );

      const manifestStore = createS3ManifestStore(s3);
      const manifest = await loadManifestWithMigration(manifestStore);

      const ladderPath = options.ladder ??
        Deno.env.get("LADDER_PATH") ??
        "ladder";
      const exporter = createLadderExporter(ladderPath, {
        onSubdivide: (size, parts) => {
          if (!options.quiet) {
            console.log(
              `    Export timed out (${size} assets) — retrying as ${parts}x${
                Math.ceil(size / parts)
              }...`,
            );
          }
        },
      });

      await runBackup(assets, manifest, manifestStore, exporter, s3, {
        batchSize: options.batchSize,
        limit: options.limit ?? 0,
        type: options.type ?? null,
        dryRun: options.dryRun ?? false,
        quiet: options.quiet ?? false,
        logger,
        notifyOnComplete: options.notify ?? false,
      });
    } finally {
      logger.close();
      reader.close();
    }
  });

main
  .command("refresh-metadata", "Re-upload metadata JSON for backed-up assets")
  .option("--dry-run", "Show what would be uploaded")
  .option("--concurrency <n:integer>", "Concurrent uploads", { default: 20 })
  .option("--bucket <name:string>", "Override bucket from config")
  .option("--db <path:string>", "Path to Photos.sqlite")
  .action(async (options: {
    dryRun?: boolean;
    concurrency: number;
    bucket?: string;
    db?: string;
  }) => {
    const { openPhotosDb } = await import("./src/photos-db/reader.ts");
    const { refreshMetadata } = await import(
      "./src/commands/refresh-metadata.ts"
    );
    const { createS3ManifestStore } = await import(
      "./src/manifest/manifest.ts"
    );
    const { createS3Provider } = await import("./src/storage/s3-client.ts");
    const { loadKeychainCredentials } = await import(
      "./src/keychain/keychain.ts"
    );

    const config = requireConfig();
    const reader = openPhotosDb(options.db);
    try {
      const assets = reader.readAssets();

      const credentials = await loadKeychainCredentials(
        config.keychain.accessKeyService,
        config.keychain.secretKeyService,
      );
      const s3 = createS3Provider(
        credentials,
        options.bucket ?? config.bucket,
        s3ConnectionFromConfig(config),
      );

      const manifestStore = createS3ManifestStore(s3);
      const manifest = await manifestStore.load();

      const report = await refreshMetadata(assets, manifest, s3, {
        concurrency: options.concurrency,
        dryRun: options.dryRun ?? false,
      });
      if (report.failed > 0) Deno.exit(2);
    } finally {
      reader.close();
    }
  });

main.command("init", "Set up attic configuration")
  .action(async () => {
    const { runInit } = await import("./src/commands/init.ts");
    await runInit();
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
    const { createS3ManifestStore } = await import(
      "./src/manifest/manifest.ts"
    );
    const { createS3Provider } = await import("./src/storage/s3-client.ts");
    const { loadKeychainCredentials } = await import(
      "./src/keychain/keychain.ts"
    );

    const config = requireConfig();

    const credentials = await loadKeychainCredentials(
      config.keychain.accessKeyService,
      config.keychain.secretKeyService,
    );
    const s3 = createS3Provider(
      credentials,
      options.bucket ?? config.bucket,
      s3ConnectionFromConfig(config),
    );
    const manifestStore = createS3ManifestStore(s3);

    if (options.rebuildManifest) {
      await rebuildManifest(s3, manifestStore);
    } else {
      const manifest = await manifestStore.load();
      await runVerify(manifest, s3, {
        deep: options.deep ?? false,
      });
    }
  });

try {
  await main.parse(Deno.args);
} catch (error: unknown) {
  handleError(error);
  Deno.exit(1);
}

function handleError(error: unknown): void {
  if (!(error instanceof Error)) {
    console.error("An unexpected error occurred.");
    return;
  }

  const msg = error.message;

  // Keychain not found
  if (
    msg.includes("find-generic-password") ||
    msg.includes("SecKeychainSearchCopyNext")
  ) {
    console.error("Could not read credentials from macOS Keychain.");
    console.error('Run "attic init" to set up your credentials.\n');
    return;
  }

  // Config missing (thrown by requireConfig)
  if (msg.includes("No config file found")) {
    console.error(msg);
    return;
  }

  // Config validation error
  if (msg.startsWith("Config:")) {
    console.error(msg);
    console.error(
      'Run "attic init" to reconfigure, or edit ~/.attic/config.json.\n',
    );
    return;
  }

  // S3 access denied
  if (msg.includes("AccessDenied") || msg.includes("403")) {
    console.error(
      "S3 access denied. Check your credentials and bucket permissions.",
    );
    console.error('Run "attic init" to update credentials.\n');
    return;
  }

  // S3 bucket not found
  if (msg.includes("NoSuchBucket")) {
    console.error(
      "S3 bucket not found. Check the bucket name in ~/.attic/config.json.",
    );
    return;
  }

  // Network error
  if (
    msg.includes("ECONNREFUSED") || msg.includes("ETIMEDOUT") ||
    msg.includes("fetch failed")
  ) {
    console.error(
      "Could not connect to S3 endpoint. Check your network and endpoint URL in ~/.attic/config.json.",
    );
    return;
  }

  // Photos.sqlite not found
  if (
    msg.includes("Photos.sqlite") || msg.includes("unable to open database")
  ) {
    console.error("Could not open Photos database.");
    console.error(
      "Make sure Photos is set up on this Mac and the database exists.\n",
    );
    return;
  }

  // Fallback
  console.error(`Error: ${msg}`);
}
