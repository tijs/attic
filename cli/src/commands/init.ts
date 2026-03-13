import { Confirm, Input, Secret } from "@cliffy/prompt";
import {
  type AtticConfig,
  configPath,
  loadConfig,
  writeConfig,
} from "../config/config.ts";
import { storeKeychainCredential } from "../keychain/keychain.ts";

const BUCKET_PATTERN = /^[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]$/;

const EU_PROVIDER_EXAMPLES = [
  "  Scaleway (EU):  https://s3.fr-par.scw.cloud",
  "  Hetzner (EU):   https://fsn1.your-objectstorage.com",
  "  OVH (EU):       https://s3.gra.io.cloud.ovh.net",
  "  AWS:            https://s3.eu-west-1.amazonaws.com",
];

export async function runInit(): Promise<void> {
  console.log("\n  attic — iCloud Photos backup to S3-compatible storage\n");

  const existing = loadConfig();
  if (existing) {
    const overwrite = await Confirm.prompt({
      message: `Config already exists at ${configPath()}. Overwrite?`,
      default: false,
    });
    if (!overwrite) {
      console.log("  Cancelled.\n");
      return;
    }
  }

  console.log("  S3 Connection");
  console.log("  " + "─".repeat(40) + "\n");
  console.log("  Provider examples:");
  for (const line of EU_PROVIDER_EXAMPLES) {
    console.log(line);
  }
  console.log();

  const endpoint = await Input.prompt({
    message: "Endpoint URL",
    validate: (v) => {
      if (!v.startsWith("https://")) return "Must start with https://";
      return true;
    },
  });

  const region = await Input.prompt({
    message: "Region",
    hint: "e.g. fr-par, eu-central-1, fsn1",
    validate: (v) => {
      if (v.trim() === "") return "Region is required";
      return true;
    },
  });

  const bucket = await Input.prompt({
    message: "Bucket name",
    validate: (v) => {
      if (v.trim() === "") return "Bucket name is required";
      if (!BUCKET_PATTERN.test(v)) {
        return "Use lowercase letters, numbers, dots, and hyphens (3-63 chars)";
      }
      return true;
    },
  });

  const pathStyle = await Confirm.prompt({
    message: "Use path-style URLs? (most S3-compatible providers need this)",
    default: true,
  });

  console.log("\n  Credentials");
  console.log("  " + "─".repeat(40) + "\n");

  const accessKey = await Input.prompt({
    message: "Access key",
  });

  const secretKey = await Secret.prompt({
    message: "Secret key",
  });

  const config: AtticConfig = {
    endpoint,
    region,
    bucket,
    pathStyle,
    keychain: {
      accessKeyService: "attic-s3-access-key",
      secretKeyService: "attic-s3-secret-key",
    },
  };

  // Write config file
  console.log(`\n  Writing config to ${configPath()}...`);
  writeConfig(config);
  console.log("  Done.");

  // Store credentials in Keychain (-U flag: update if exists, create if not)
  console.log("  Storing credentials in macOS Keychain...");
  await storeKeychainCredential(
    config.keychain.accessKeyService,
    accessKey,
  );
  await storeKeychainCredential(
    config.keychain.secretKeyService,
    secretKey,
  );
  console.log("  Done.");

  console.log(
    '\n  Setup complete. Run "attic scan" to see your Photos library.\n',
  );
}
