# UX and Open-Source Readiness

**Date:** 2026-03-13
**Status:** Ready for planning

## What We're Building

Make attic friendly to use for technical Mac users and ready to open source. Replace hardcoded Scaleway configuration with a generic S3-compatible config layer, add an interactive `attic init` command, adopt Cliffy for polished CLI output, and improve error messages throughout.

## Why This Approach

Attic currently works well as a personal tool but has Scaleway details baked into the code (endpoint, region, keychain service names, type names). To open source it, the tool needs to work with any S3-compatible provider out of the box. The UX should feel polished — good help text, colored output, and clear error messages that tell you what to do next.

## Current State

| Area | Current | Target |
|------|---------|--------|
| S3 endpoint/region | Hardcoded Scaleway constants | Config file, any S3-compatible provider |
| Bucket name | Hardcoded default, `--bucket` flag | Config file, CLI override |
| Credentials | Keychain with hardcoded service names | Keychain with configurable service names |
| Config file | None | `~/.attic/config.json` |
| First-run setup | Manual (read README, set keychain, run) | `attic init` interactive prompts |
| CLI framework | Hand-rolled arg parsing | Cliffy (subcommands, typed flags, help, color) |
| Error messages | Raw exceptions in some paths | Friendly messages with suggested fixes |
| path style | Hardcoded `true` | Config option, default `true` |
| Provider docs | Scaleway-specific | Provider-neutral with EU-focused examples |

## Key Decisions

1. **Config file at `~/.attic/config.json`** — primary configuration source. CLI flags override. No env var fallback (keep it simple, macOS-only tool).

2. **Interactive `attic init`** — asks for S3 endpoint, region, bucket, and keychain service names step by step. Writes config.json. Can offer provider suggestions (Scaleway, Hetzner, OVH as EU options).

3. **Keychain with configurable service names** — stay macOS Keychain-only (security principle from CLAUDE.md), but let config.json specify the service names instead of hardcoding `attic-s3-access-key` / `attic-s3-secret-key`.

4. **Cliffy for CLI** — replace hand-rolled arg parsing with Cliffy. Gets us subcommands, typed flags, auto-generated help, colored output, and shell completions.

5. **`forcePathStyle` as config option** — default `true` (works with most S3-compatible providers). AWS users can set to `false`.

6. **EU-focused provider examples** — highlight Scaleway, Hetzner, OVH as EU data sovereignty options in docs and init prompts. Mention AWS/Backblaze as alternatives. Position attic as a good choice for keeping your photos in the EU.

7. **Top-level error boundary** — catch unhandled errors in mod.ts, present friendly messages instead of stack traces. Pattern: detect known error types (keychain missing, network timeout, S3 access denied) and print actionable guidance.

## Config File Schema

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

## Scope

### In scope
- Config file (`~/.attic/config.json`) with validation
- `attic init` interactive setup command
- Cliffy migration for all commands (scan, status, backup, verify)
- Rename `ScalewayCredentials` to `S3Credentials`, remove `SCALEWAY_*` constants
- `createS3Provider()` accepts endpoint, region, pathStyle as parameters
- Top-level error boundary with friendly messages for known failure modes
- Updated README, CLAUDE.md, and architecture docs
- EU-focused provider examples in docs and init

### Out of scope
- Env var credential fallback (keep Keychain-only)
- Non-macOS support
- Provider presets in init (just ask for endpoint/region directly, with examples)
- Web UI or GUI
- Auto-detection of Photos.sqlite path across macOS versions

## Resolved Questions

1. **Audience**: Technical Mac users comfortable with terminal and S3 setup.
2. **Config approach**: Config file at `~/.attic/config.json`, CLI flags override.
3. **Init style**: Interactive prompts, writes config at the end.
4. **Credentials**: Keychain-only with configurable service names in config.
5. **Provider presentation**: EU-focused examples (Scaleway, Hetzner, OVH), others mentioned as alternatives.
6. **Path style**: Config option `pathStyle`, default `true`.
7. **CLI framework**: Cliffy.
8. **Init stores credentials directly**: `attic init` prompts for access key and secret key and runs `security add-generic-password` automatically.
9. **Validate config when S3 is needed**: scan/status only need Photos.sqlite — they work without config. backup/verify validate config and fail fast with a clear message if missing or incomplete.
