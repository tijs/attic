import { requireConfig } from "./src/config/config.ts";

const command = Deno.args[0];

switch (command) {
  case "scan": {
    const { openPhotosDb } = await import("./src/photos-db/reader.ts");
    const { printScanReport } = await import("./src/commands/scan.ts");

    const dbPath = Deno.args[1]; // optional override
    const reader = openPhotosDb(dbPath);
    try {
      const assets = reader.readAssets();
      printScanReport(assets);
    } finally {
      reader.close();
    }
    break;
  }
  case "status": {
    const { openPhotosDb } = await import("./src/photos-db/reader.ts");
    const { printStatusReport } = await import("./src/commands/status.ts");
    const { createManifestStore } = await import("./src/manifest/manifest.ts");

    const dbPath = Deno.args[1]; // optional override
    const reader = openPhotosDb(dbPath);
    try {
      const assets = reader.readAssets();
      const manifestStore = createManifestStore();
      await printStatusReport(assets, manifestStore);
    } finally {
      reader.close();
    }
    break;
  }
  case "backup": {
    const { openPhotosDb } = await import("./src/photos-db/reader.ts");
    const { runBackup } = await import("./src/commands/backup.ts");
    const { createManifestStore } = await import("./src/manifest/manifest.ts");
    const { createS3Provider, loadKeychainCredentials } = await import(
      "./src/storage/s3-client.ts"
    );
    const { createLadderExporter } = await import("./src/export/exporter.ts");

    const flags = parseBackupFlags(Deno.args.slice(1));
    const config = requireConfig();
    const reader = openPhotosDb(flags.dbPath);
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
        flags.bucket ?? config.bucket,
        {
          endpoint: config.endpoint,
          region: config.region,
          pathStyle: config.pathStyle,
        },
      );

      const ladderPath = flags.ladderPath ??
        Deno.env.get("LADDER_PATH") ??
        "ladder";
      const exporter = createLadderExporter(ladderPath);

      await runBackup(assets, manifest, manifestStore, exporter, s3, {
        batchSize: flags.batchSize,
        limit: flags.limit,
        type: flags.type,
        dryRun: flags.dryRun,
      });
    } finally {
      reader.close();
    }
    break;
  }
  case "verify": {
    const { runVerify } = await import("./src/commands/verify.ts");
    const { rebuildManifest } = await import("./src/commands/rebuild.ts");
    const { createManifestStore } = await import("./src/manifest/manifest.ts");
    const { createS3Provider, loadKeychainCredentials } = await import(
      "./src/storage/s3-client.ts"
    );

    const verifyFlags = parseVerifyFlags(Deno.args.slice(1));
    const config = requireConfig();

    const credentials = await loadKeychainCredentials(
      config.keychain.accessKeyService,
      config.keychain.secretKeyService,
    );
    const s3 = createS3Provider(
      credentials,
      verifyFlags.bucket ?? config.bucket,
      {
        endpoint: config.endpoint,
        region: config.region,
        pathStyle: config.pathStyle,
      },
    );
    const manifestStore = createManifestStore();

    if (verifyFlags.rebuildManifest) {
      await rebuildManifest(s3, manifestStore);
    } else {
      const manifest = await manifestStore.load();
      await runVerify(manifest, s3, {
        deep: verifyFlags.deep,
      });
    }
    break;
  }
  default:
    console.log(`attic — iCloud Photos backup to S3-compatible storage\n`);
    console.log(`Commands:`);
    console.log(`  scan      Scan Photos library and show statistics`);
    console.log(`  status    Compare Photos DB vs backup manifest`);
    console.log(`  backup    Back up pending assets to S3`);
    console.log(`  verify    Verify backup integrity against S3`);
    console.log(`\nBackup flags:`);
    console.log(`  --dry-run          Show what would be uploaded`);
    console.log(`  --limit N          Back up at most N assets`);
    console.log(`  --batch-size N     Assets per ladder batch (default: 50)`);
    console.log(`  --type photo|video Only back up photos or videos`);
    console.log(`  --bucket NAME      S3 bucket (overrides config)`);
    console.log(`  --ladder PATH      Path to ladder binary`);
    console.log(`  --db PATH          Path to Photos.sqlite`);
    console.log(`\nVerify flags:`);
    console.log(`  --deep             Download and re-checksum each object`);
    console.log(`  --rebuild-manifest Reconstruct manifest from S3 metadata`);
    console.log(`  --bucket NAME      S3 bucket (overrides config)`);
    console.log(`\nUsage: deno task <command>`);
    if (command) {
      console.error(`\nUnknown command: ${command}`);
      Deno.exit(1);
    }
}

interface BackupFlags {
  dryRun: boolean;
  limit: number;
  batchSize: number;
  type: "photo" | "video" | null;
  bucket: string | null;
  ladderPath: string | null;
  dbPath: string | undefined;
}

function requireArg(args: string[], i: number, flag: string): string {
  const value = args[i];
  if (value === undefined) {
    console.error(`Missing value for ${flag}`);
    Deno.exit(1);
  }
  return value;
}

function parsePositiveInt(value: string, flag: string): number {
  const n = parseInt(value, 10);
  if (!Number.isFinite(n) || n < 1) {
    console.error(`${flag} must be a positive integer, got: ${value}`);
    Deno.exit(1);
  }
  return n;
}

function parseBackupFlags(args: string[]): BackupFlags {
  const flags: BackupFlags = {
    dryRun: false,
    limit: 0,
    batchSize: 50,
    type: null,
    bucket: null,
    ladderPath: null,
    dbPath: undefined,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    switch (arg) {
      case "--dry-run":
        flags.dryRun = true;
        break;
      case "--limit":
        flags.limit = parsePositiveInt(
          requireArg(args, ++i, "--limit"),
          "--limit",
        );
        break;
      case "--batch-size":
        flags.batchSize = parsePositiveInt(
          requireArg(args, ++i, "--batch-size"),
          "--batch-size",
        );
        break;
      case "--type": {
        const typeVal = requireArg(args, ++i, "--type");
        if (typeVal !== "photo" && typeVal !== "video") {
          console.error(`--type must be "photo" or "video", got: ${typeVal}`);
          Deno.exit(1);
        }
        flags.type = typeVal;
        break;
      }
      case "--bucket":
        flags.bucket = requireArg(args, ++i, "--bucket");
        break;
      case "--ladder":
        flags.ladderPath = requireArg(args, ++i, "--ladder");
        break;
      case "--db":
        flags.dbPath = requireArg(args, ++i, "--db");
        break;
      case "--":
        break;
      default:
        console.error(`Unknown flag: ${arg}`);
        Deno.exit(1);
    }
  }

  return flags;
}

interface VerifyFlags {
  deep: boolean;
  rebuildManifest: boolean;
  bucket: string | null;
}

function parseVerifyFlags(args: string[]): VerifyFlags {
  const flags: VerifyFlags = {
    deep: false,
    rebuildManifest: false,
    bucket: null,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    switch (arg) {
      case "--deep":
        flags.deep = true;
        break;
      case "--rebuild-manifest":
        flags.rebuildManifest = true;
        break;
      case "--bucket":
        flags.bucket = requireArg(args, ++i, "--bucket");
        break;
      case "--":
        break;
      default:
        console.error(`Unknown flag: ${arg}`);
        Deno.exit(1);
    }
  }

  return flags;
}
