---
title: "feat: UX and Open-Source Readiness"
type: feat
status: active
date: 2026-03-13
---

# UX and Open-Source Readiness

## Overview

Replace hardcoded Scaleway configuration with a generic S3-compatible config layer, add an interactive `attic init` command, migrate CLI to Cliffy, and improve error messages. Makes attic usable with any S3-compatible provider and ready to open source.

## Problem Statement

Attic has Scaleway details baked into the code — endpoint, region, keychain service names, type names. A user who wants to use Hetzner, OVH, or AWS must fork and edit constants. The CLI uses hand-rolled arg parsing (130+ lines in `cli/mod.ts`) with no help generation, no colored output, and no shell completions. Error messages are raw exceptions in some paths.

## Proposed Solution

Five phases, each independently shippable:

1. **Config layer** — `~/.attic/config.json` with validation
2. **Generic S3** — rename types, parameterize `createS3Provider()`
3. **Cliffy CLI** — replace hand-rolled parsing with Cliffy subcommands
4. **Interactive init** — `attic init` prompts for config + credentials
5. **Error boundary** — top-level catch with friendly messages

## Steps

### Phase 1: Config Layer

Add config file support at `~/.attic/config.json`.

**Files to modify:**
- New: `cli/src/config/config.ts` (~80 lines)
- New: `cli/src/config/config.test.ts` (~60 lines)

**Config schema:**

```json
{
  "endpoint": "https://s3.fr-par.scw.cloud",
  "region": "fr-par",
  "bucket": "my-photo-backup",
  "pathStyle": true,
  "keychain": {
    "accessKeyService": "attic-s3-access-key",
    "secretKeyService": "attic-s3-secret-key"
  }
}
```

**Implementation:**

```typescript
// cli/src/config/config.ts
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

const CONFIG_DIR = join(homedir(), ".attic");
const CONFIG_PATH = join(CONFIG_DIR, "config.json");

/** Load and validate config. Returns null if file doesn't exist. */
export function loadConfig(): AtticConfig | null

/** Validate config fields, throw with specific message on missing/invalid. */
export function validateConfig(raw: unknown): AtticConfig

/** Write config to disk, creating ~/.attic/ if needed. */
export function writeConfig(config: AtticConfig): void
```

**Validation rules:**
- `endpoint` — required, must start with `https://`
- `region` — required, non-empty string
- `bucket` — required, non-empty string, validated against `/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/`
- `pathStyle` — optional, defaults to `true`
- `keychain.accessKeyService` — optional, defaults to `"attic-s3-access-key"`
- `keychain.secretKeyService` — optional, defaults to `"attic-s3-secret-key"`

**Tests:**
- Valid config round-trips through write/load
- Missing required fields throw descriptive errors
- Optional fields get defaults
- Config file not found returns null
- Invalid endpoint (no https) rejected
- Invalid bucket name rejected

### Phase 2: Generic S3

Remove Scaleway-specific naming. Parameterize the S3 client.

**Files to modify:**
- `cli/src/storage/s3-client.ts` (~20 lines changed)
- `cli/mod.ts` (~15 lines changed)
- `deno.json` (~2 lines changed — remove `--allow-net=s3.fr-par.scw.cloud`, use broader net permission)

**Changes:**

```typescript
// s3-client.ts — before
export interface ScalewayCredentials { ... }
const SCALEWAY_ENDPOINT = "https://s3.fr-par.scw.cloud";
const SCALEWAY_REGION = "fr-par";
export function createS3Provider(credentials: ScalewayCredentials, bucket: string): S3Provider

// s3-client.ts — after
export interface S3Credentials {
  accessKeyId: string;
  secretAccessKey: string;
}

export interface S3ConnectionConfig {
  endpoint: string;
  region: string;
  pathStyle: boolean;
}

export function createS3Provider(
  credentials: S3Credentials,
  bucket: string,
  connection: S3ConnectionConfig,
): S3Provider
```

- `loadKeychainCredentials()` accepts service names as parameters instead of hardcoding them
- Delete `SCALEWAY_ENDPOINT` and `SCALEWAY_REGION` constants
- `cli/mod.ts` reads config and passes connection details to `createS3Provider()`
- `deno.json` tasks: replace `--allow-net=s3.fr-par.scw.cloud` with `--allow-net` (endpoint is now configurable)

**Migration for existing users:** scan/status continue working without config (they don't need S3). backup/verify check for config and fail fast:

```
Error: No config file found at ~/.attic/config.json
Run "attic init" to set up your S3 connection, or create the file manually.
See: https://github.com/tijs/attic#setup
```

### Phase 3: Cliffy CLI

Replace hand-rolled arg parsing with Cliffy.

**Dependencies to add (JSR):**
- `@cliffy/command@1.0.0`
- `@cliffy/prompt@1.0.0`
- `@cliffy/ansi@1.0.0`

**Files to modify:**
- `cli/mod.ts` — full rewrite (~120 lines, replaces 252 lines)
- `cli/deno.json` — add Cliffy imports

**New structure:**

```typescript
// cli/mod.ts
import { Command } from "@cliffy/command";

const main = new Command()
  .name("attic")
  .version("0.1.0")
  .description("Back up your iCloud Photos library to S3-compatible storage")
  .action(() => main.showHelp());

// Each command in its own .command() chain
main.command("scan", "Scan Photos library and show statistics")
  .option("--db <path:string>", "Path to Photos.sqlite")
  .action(async ({ db }) => { ... });

main.command("status", "Compare Photos DB vs backup manifest")
  .option("--db <path:string>", "Path to Photos.sqlite")
  .action(async ({ db }) => { ... });

main.command("backup", "Back up pending assets to S3")
  .option("--dry-run", "Show what would be uploaded")
  .option("--limit <n:integer>", "Back up at most N assets")
  .option("--batch-size <n:integer>", "Assets per ladder batch", { default: 50 })
  .option("--type <type:string>", "Only back up photos or videos")
  .option("--bucket <name:string>", "Override bucket from config")
  .option("--ladder <path:string>", "Path to ladder binary")
  .option("--db <path:string>", "Path to Photos.sqlite")
  .action(async (options) => { ... });

main.command("verify", "Verify backup integrity against S3")
  .option("--deep", "Download and re-checksum each object")
  .option("--rebuild-manifest", "Reconstruct manifest from S3 metadata")
  .option("--bucket <name:string>", "Override bucket from config")
  .action(async (options) => { ... });

main.command("init", "Set up attic configuration")
  .action(async () => { ... });

await main.parse(Deno.args);
```

**What this gives us:**
- Auto-generated `--help` for every command
- Typed flags with validation (`:integer`, `:string`)
- Unknown flag detection
- Version flag (`--version`)
- Shell completions via `main.command("completions", ...).action(completeCommand)`

**What we delete:**
- `parseBackupFlags()` (~55 lines)
- `parseVerifyFlags()` (~30 lines)
- `requireArg()`, `parsePositiveInt()` (~15 lines)
- Manual help text block (~25 lines)

### Phase 4: Interactive Init

Add `attic init` command with interactive prompts.

**Files to modify:**
- New: `cli/src/commands/init.ts` (~120 lines)
- `cli/mod.ts` — wire up init command

**Flow:**

```
$ attic init

  attic — iCloud Photos backup to S3-compatible storage

  S3 Connection
  ─────────────

  Endpoint URL: https://s3.fr-par.scw.cloud
    Examples:
    · Scaleway (EU):  https://s3.fr-par.scw.cloud
    · Hetzner (EU):   https://fsn1.your-objectstorage.com
    · OVH (EU):       https://s3.gra.io.cloud.ovh.net
    · AWS:            https://s3.eu-west-1.amazonaws.com

  Region: fr-par

  Bucket name: my-photo-backup

  Use path-style URLs? (Y/n): Y
    Most S3-compatible providers need this. AWS users: set to No.

  Credentials
  ───────────

  Access key: SCWXXXXXXXXXXXXXXXXX
  Secret key: ········································

  Writing config to ~/.attic/config.json... done
  Storing credentials in macOS Keychain... done

  ✓ Setup complete. Run "attic scan" to see your Photos library.
```

**Implementation:**

```typescript
// cli/src/commands/init.ts
import { Input, Confirm, Secret } from "@cliffy/prompt";
import { colors } from "@cliffy/ansi";

export async function runInit(): Promise<void> {
  // Check for existing config
  const existing = loadConfig();
  if (existing) {
    const overwrite = await Confirm.prompt("Config already exists. Overwrite?");
    if (!overwrite) return;
  }

  const endpoint = await Input.prompt({ message: "Endpoint URL", hint: "..." });
  const region = await Input.prompt({ message: "Region" });
  const bucket = await Input.prompt({ message: "Bucket name" });
  const pathStyle = await Confirm.prompt({ message: "Use path-style URLs?", default: true });

  const accessKey = await Input.prompt({ message: "Access key" });
  const secretKey = await Secret.prompt({ message: "Secret key" });

  // Write config
  writeConfig({ endpoint, region, bucket, pathStyle, keychain: {
    accessKeyService: "attic-s3-access-key",
    secretKeyService: "attic-s3-secret-key",
  }});

  // Store credentials with -U flag (update if exists)
  await storeKeychainCredential("attic-s3-access-key", accessKey);
  await storeKeychainCredential("attic-s3-secret-key", secretKey);
}

async function storeKeychainCredential(service: string, value: string): Promise<void> {
  // Try update first, fall back to add
  const update = new Deno.Command("security", {
    args: ["add-generic-password", "-U", "-s", service, "-a", "attic", "-w", value],
    stderr: "piped",
  });
  const { code } = await update.output();
  if (code !== 0) {
    throw new Error(`Failed to store credential in Keychain for service "${service}"`);
  }
}
```

**Keychain idempotency:** Use `security add-generic-password -U` which updates an existing entry or creates a new one. No need to delete-then-add.

**No test file for init** — it's pure I/O (prompts + Keychain + file writes). The config validation is tested in Phase 1. Keychain interaction is tested manually.

### Phase 5: Error Boundary

Add a top-level error handler in `cli/mod.ts`.

**Files to modify:**
- `cli/mod.ts` (~40 lines added)

**Implementation:**

```typescript
// Wrap main.parse() in try/catch
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
  if (msg.includes("find-generic-password") || msg.includes("SecKeychainSearchCopyNext")) {
    console.error("Could not read credentials from macOS Keychain.");
    console.error('Run "attic init" to set up your credentials.\n');
    return;
  }

  // Config missing
  if (msg.includes("config.json") && msg.includes("ENOENT")) {
    console.error("No config file found at ~/.attic/config.json");
    console.error('Run "attic init" to set up your S3 connection.\n');
    return;
  }

  // S3 access denied
  if (msg.includes("AccessDenied") || msg.includes("403")) {
    console.error("S3 access denied. Check your credentials and bucket permissions.");
    console.error("Your credentials are stored in macOS Keychain.");
    console.error('Run "attic init" to update them.\n');
    return;
  }

  // S3 bucket not found
  if (msg.includes("NoSuchBucket") || msg.includes("404")) {
    console.error(`S3 bucket not found. Check the bucket name in ~/.attic/config.json`);
    return;
  }

  // Network error
  if (msg.includes("ECONNREFUSED") || msg.includes("ETIMEDOUT") || msg.includes("fetch failed")) {
    console.error("Could not connect to S3 endpoint. Check your network and endpoint URL.");
    return;
  }

  // Photos.sqlite not found
  if (msg.includes("Photos.sqlite") || msg.includes("no such file")) {
    console.error("Could not open Photos database.");
    console.error("Make sure Photos is set up on this Mac and the database exists.");
    return;
  }

  // Fallback
  console.error(`Error: ${msg}`);
}
```

## Files Summary

| Phase | File | Change |
|-------|------|--------|
| 1 | `cli/src/config/config.ts` | New — config load/validate/write |
| 1 | `cli/src/config/config.test.ts` | New — config tests |
| 2 | `cli/src/storage/s3-client.ts` | Rename types, parameterize |
| 2 | `cli/mod.ts` | Read config, pass to S3 |
| 2 | `deno.json` | Broader net permission |
| 3 | `cli/mod.ts` | Rewrite with Cliffy |
| 3 | `cli/deno.json` | Add Cliffy imports |
| 4 | `cli/src/commands/init.ts` | New — interactive setup |
| 5 | `cli/mod.ts` | Error boundary wrapper |

## Verification

After each phase:
1. `deno task check` — type checking
2. `deno task test` — all tests pass
3. `deno task lint` — no lint errors

Integration test (after all phases):
1. Run `attic init` with a test bucket
2. Run `attic scan` — works without config
3. Run `attic backup --dry-run` — reads config, validates, shows plan
4. Run `attic verify` — reads config, connects to S3

## Dependencies

- `@cliffy/command@1.0.0` (JSR) — subcommands, typed flags, help generation
- `@cliffy/prompt@1.0.0` (JSR) — interactive prompts for init
- `@cliffy/ansi@1.0.0` (JSR) — colored output

All three are Deno 2+ compatible via JSR. No npm dependencies.

## Out of Scope

- Env var credential fallback (keep Keychain-only)
- Non-macOS support
- Provider presets/auto-detection in init
- Web UI or GUI
- Auto-detection of Photos.sqlite path across macOS versions
- Shell completion generation (Cliffy supports it, but we can add it later)
