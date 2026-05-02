---
title: Percent-encode externally-sourced identifiers before embedding in S3 keys or filesystem paths
date: 2026-05-02
category: docs/solutions/runtime-errors
module: AtticCore
problem_type: runtime_error
component: service_object
symptoms:
  - "`Error: Unsafe UUID for S3 key: 41C24A89-1280-4C14-BF5E-E93545843128:001:AaiU4soYcBEybZPj3zsS91dxDF42`"
  - "`Error: Unsafe UUID for S3 key: D0AEBE57-D551-401D-8C38-0C8AECE6FB60:001:ARhjT/vuVrN8DGhjUDrTItEm0vIq`"
  - "`attic migrate` aborts before any rewrite happens; v1 manifest left untouched"
root_cause: missing_validation
resolution_type: code_fix
severity: high
related_components:
  - tooling
tags:
  - s3
  - photokit
  - url-encoding
  - cloud-identity
  - validation
---

# Percent-encode externally-sourced identifiers before embedding in S3 keys or filesystem paths

## Problem
The cloud-identity migration from device-local UUIDs to `PHCloudIdentifier.stringValue` shipped with a strict validator regex that rejected legitimate cloud identifiers. Every iteration that widened the regex hit the next character class PhotoKit uses, requiring three back-to-back hotfix releases (beta.8, beta.9, beta.10) before the system handled real-world cloud IDs.

## Symptoms
- `attic migrate` aborts with `Unsafe UUID for S3 key: <full cloud id>` mid-migration
- Each hotfix moved the wall: beta.8 hit on `:`, beta.9 hit on `/`, the next would have hit on `+` or `=`
- v1 → v2 manifest migration leaves the bucket in a partial state; recovery requires `attic migrate --repair`

## What Didn't Work
- **Beta.8 validator regex `^[A-Za-z0-9._\-]+$`** — rejected the `:` separators in `<UUID>:<index>:<base64>` cloud identifiers. Migration aborted on the first cloud ID it tried to rewrite.
- **Beta.9 fix: add `:` to the regex** — accepted the colon-separated structure but PhotoKit's third segment is standard base64, which uses `+`, `/`, `=`. The next user hit a cloud ID containing `/` and migration aborted again.
- **Mental model "enumerate the alphabet"** — each iteration was a guess at what characters PhotoKit emits. There is no public API listing the full character set, and Apple is free to change the encoding. Allowlist-as-validator is a treadmill.

## Solution
Switch from alphabet enumeration to **structural percent-encoding**. The validator accepts the full PhotoKit alphabet so legitimate cloud IDs pass through; safety comes from encoding the identifier into a single path component before constructing keys.

```swift
// Sources/AtticCore/S3Paths.swift

// Validator accepts the full PhotoKit cloud-id shape — no enumeration of the
// exact base64 alphabet PhotoKit happens to use today.
private nonisolated(unsafe) static let uuidPattern = /^[A-Za-z0-9._\-:+\/=]+$/

// RFC 3986 unreserved characters. Anything outside is percent-encoded.
private nonisolated(unsafe) static let unreservedURLChars: CharacterSet = {
    var set = CharacterSet()
    set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return set
}()

public static func encodeUUIDComponent(_ uuid: String) -> String {
    uuid.addingPercentEncoding(withAllowedCharacters: unreservedURLChars) ?? uuid
}

public static func metadataKey(uuid: String) throws -> String {
    try assertSafeUUID(uuid)
    return "metadata/assets/\(encodeUUIDComponent(uuid)).json"
}
```

Apply the same encoding everywhere the identifier becomes part of a path component, including local filesystem paths:

```swift
// Sources/AtticCore/ThumbnailCache.swift
let path = directory.appendingPathComponent("\(S3Paths.encodeUUIDComponent(uuid)).jpg")
```

## Why This Works
- **RFC 3986 unreserved is a closed set**: `A-Za-z0-9-._~`. Anything outside is path-reserved, which is exactly what we need to encode away to keep a single path component.
- **No alphabet guesses**: future PhotoKit shapes (more colons, different base64 variants, accented characters, anything) flow through the encoder unchanged — the encoder doesn't care what the input alphabet is.
- **Structural separators stay unambiguous**: the only `/` in `metadata/assets/<encoded>.json` is the one we wrote. Cloud IDs containing `/` cannot escape their bucket prefix because the `/` is encoded to `%2F`.
- **Round-trip is lossless**: `removingPercentEncoding` recovers the original cloud ID for manifest lookups, JSON storage, and any code that needs the raw identifier.

## Prevention
- **Treat externally-sourced identifiers as untrusted strings, not validated tokens.** PhotoKit, Apple frameworks, and third-party SDKs do not promise stable character sets. The right defense is encoding at the boundary, not allowlisting at validation.
- **Validators allow the full producer alphabet; encoders enforce path safety.** Two responsibilities, two layers. A validator that doubles as a safety boundary breaks every time the producer surfaces a new character.
- **Encode at every path-component boundary**: S3 keys, filesystem paths, presigned URLs, content-disposition filenames, log labels. A single missed call site reintroduces the bug.
- **Test with realistic external-data fixtures**: capture three or four real `PHCloudIdentifier.stringValue` shapes (colons-only, base64 with `/`, base64 with `+`/`=`) and assert end-to-end key construction. See `Tests/AtticCoreTests/CloudIdentifierShapeTests.swift` — the regression suite that would have caught the beta.9 → beta.10 step before release.
- **When a hotfix widens an allowlist regex once, treat it as a smell, not a fix.** Two widenings in a row mean the regex is doing the wrong job; switch strategies.

## Related Issues
- `docs/migration-cloud-identity.md` — v1 → v2 manifest migration design
- Hotfix chain commits: `724fe39` (beta.9 colon), `336fac9` (beta.10 percent-encode)
- Tests: `Tests/AtticCoreTests/CloudIdentifierShapeTests.swift`
- See also: `docs/solutions/runtime-errors/url-appendingpathcomponent-double-encodes-percent-2026-05-02.md` (consumer side — preserving the encoding through URL construction)
