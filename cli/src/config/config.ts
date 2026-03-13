import { join } from "@std/path/join";

export interface AtticConfig {
  endpoint: string;
  region: string;
  bucket: string;
  pathStyle: boolean;
  keychain: {
    accessKeyService: string;
    secretKeyService: string;
  };
}

const CONFIG_DIR = join(
  Deno.env.get("HOME") ?? "~",
  ".attic",
);

const CONFIG_PATH = join(CONFIG_DIR, "config.json");

const BUCKET_PATTERN = /^[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]$/;

/** Load config from ~/.attic/config.json. Returns null if file doesn't exist. */
export function loadConfig(dir: string = CONFIG_DIR): AtticConfig | null {
  const path = join(dir, "config.json");
  let text: string;
  try {
    text = Deno.readTextFileSync(path);
  } catch (error: unknown) {
    if (error instanceof Deno.errors.NotFound) {
      return null;
    }
    throw error;
  }
  const raw: unknown = JSON.parse(text);
  return validateConfig(raw);
}

/** Validate a raw parsed config object. Throws with specific messages on invalid fields. */
export function validateConfig(raw: unknown): AtticConfig {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new Error("Config must be a JSON object");
  }

  const obj = raw as Record<string, unknown>;

  if (typeof obj.endpoint !== "string" || obj.endpoint === "") {
    throw new Error(
      'Config: "endpoint" is required (e.g. "https://s3.fr-par.scw.cloud")',
    );
  }
  if (!obj.endpoint.startsWith("https://")) {
    throw new Error('Config: "endpoint" must start with https://');
  }

  if (typeof obj.region !== "string" || obj.region === "") {
    throw new Error('Config: "region" is required (e.g. "fr-par")');
  }

  if (typeof obj.bucket !== "string" || obj.bucket === "") {
    throw new Error('Config: "bucket" is required');
  }
  if (!BUCKET_PATTERN.test(obj.bucket)) {
    throw new Error(
      `Config: "bucket" name "${obj.bucket}" is invalid. ` +
        "Use lowercase letters, numbers, dots, and hyphens (3-63 chars).",
    );
  }

  const pathStyle = obj.pathStyle !== undefined ? Boolean(obj.pathStyle) : true;

  const keychain = typeof obj.keychain === "object" && obj.keychain !== null &&
      !Array.isArray(obj.keychain)
    ? obj.keychain as Record<string, unknown>
    : {};

  const accessKeyService = typeof keychain.accessKeyService === "string" &&
      keychain.accessKeyService !== ""
    ? keychain.accessKeyService
    : "attic-s3-access-key";

  const secretKeyService = typeof keychain.secretKeyService === "string" &&
      keychain.secretKeyService !== ""
    ? keychain.secretKeyService
    : "attic-s3-secret-key";

  return {
    endpoint: obj.endpoint,
    region: obj.region,
    bucket: obj.bucket,
    pathStyle,
    keychain: { accessKeyService, secretKeyService },
  };
}

/** Write config to disk, creating ~/.attic/ if needed. */
export function writeConfig(
  config: AtticConfig,
  dir: string = CONFIG_DIR,
): void {
  Deno.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const path = join(dir, "config.json");
  Deno.writeTextFileSync(
    path,
    JSON.stringify(config, null, 2) + "\n",
    { mode: 0o600 },
  );
}

/** Resolve the default config file path. */
export function configPath(): string {
  return CONFIG_PATH;
}

/**
 * Load and validate config, throwing a user-friendly error if missing.
 * Use this for commands that require S3 (backup, verify).
 */
export function requireConfig(dir?: string): AtticConfig {
  const config = loadConfig(dir);
  if (config === null) {
    const path = dir ? join(dir, "config.json") : configPath();
    throw new Error(
      `No config file found at ${path}\n` +
        'Run "attic init" to set up your S3 connection, or create the file manually.',
    );
  }
  return config;
}
