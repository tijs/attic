import { Confirm, Input, Secret } from "@cliffy/prompt";
import {
  type AtticConfig,
  configPath,
  loadConfig,
  writeConfig,
} from "../config/config.ts";

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
  });

  const bucket = await Input.prompt({
    message: "Bucket name",
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

async function storeKeychainCredential(
  service: string,
  value: string,
): Promise<void> {
  const cmd = new Deno.Command("security", {
    args: [
      "add-generic-password",
      "-U",
      "-s",
      service,
      "-a",
      "attic",
      "-w",
      value,
    ],
    stderr: "piped",
  });
  const { code, stderr } = await cmd.output();
  if (code !== 0) {
    const err = new TextDecoder().decode(stderr);
    throw new Error(
      `Failed to store credential in Keychain for service "${service}": ${err.trim()}`,
    );
  }
}
