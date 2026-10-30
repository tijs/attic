# Restore verified originals

Issue: https://github.com/tijs/attic/issues/8

`attic restore` recovers original files from an S3 or filesystem backup, checks
SHA-256 and available size information, and writes a local recovery journal and
metadata sidecars. It does not need the old Mac, Photos library, or PhotoKit
permission. It reads v1 and v2 manifests directly without identity migration.

## Recover on a fresh Mac

Configure access to the existing backup, then choose an existing local directory:

```sh
attic init --profile recovery
mkdir ~/RecoveredPhotos
attic restore --profile recovery --destination ~/RecoveredPhotos --dry-run
attic restore --profile recovery --destination ~/RecoveredPhotos
```

For a filesystem backup, attach its original volume and bind a new local profile
to the existing target. Its identity marker must still match the volume and root
inode:

```sh
attic init --profile recovery --filesystem /Volumes/PhotoBackup/Attic
attic restore --profile recovery --destination ~/RecoveredPhotos
```

The recovery directory must neither contain the filesystem backup's directory
nor be inside it. The two directory trees must be disjoint.
No original or manifest is rewritten by recovery. `init` and the destination
lock use internal target bookkeeping; they do not rewrite backed-up originals.
If the manifest is missing or damaged, `restore` stops with instructions to run
`attic rebuild` using the same profile. `rebuild` reconstructs manifest records
from the stored metadata; it does not download originals. Keep a copy of a
damaged manifest before deliberately rebuilding it.

Without `--profile`, recovery reads the existing default S3 configuration.
`restore` never imports a legacy local manifest into a newly selected target and
never runs cloud-identity migration or orphan-thumbnail cleanup. S3 credentials
and read permission are required for S3; filesystem sources need no credentials.

## Selection

```sh
attic restore --profile recovery --destination ~/RecoveredPhotos \
  --from 2024-01-01 --through 2024-12-31 --type photo --album ALBUM-UUID
```

Dates are UTC calendar days. `--from` includes the day's beginning, and
`--through` includes the whole day, ending before the next UTC midnight.
Stored ISO 8601 creation dates may include fractional seconds and UTC offsets.
`--type` accepts `photo` or `video` based on the stored uniform type identifier.
`--album` matches an exact album UUID in the backup metadata, not a title or a
current Photos album. Filters combine with AND.

Date/type/album selection requires valid, consistent metadata for every candidate
manifest entry. Missing fields, missing/unreadable metadata, or identity/checksum
mismatches stop filtered selection rather than silently leaving unknown originals
out of the recovery. With no filters, verified manifest originals remain
recoverable without metadata; missing or inconsistent metadata is reported as a
warning, and the sidecar records the absence. Unknown checksum algorithms or
malformed original keys always stop planning before original downloads.

Every distinct original object key is recovered once, even if multiple manifest
entries refer to it. Conflicting checksums/sizes for a shared key are rejected.
Every resource actually represented in the manifest is eligible. The current
Ladder exporter preserves a primary resource for Live Photos; a motion component
or edit-history resource never backed up cannot be recreated by restore.

`--dry-run` prints the selection count and up to twenty deterministic local paths
and sizes. It creates no recovery files, makes no archive retrieval requests and
does not launch Photos, even when effectful flags are also present. Metadata
reads are still necessary for planning and filters.

## Integrity, collisions and resume

Files use lowercase SHA-256-derived names under `files/`, with a safe extension.
Equal original filenames, cloud identifiers containing slashes, differing case,
and Unicode normalization cannot make two object keys share a normal destination
path. Original filenames, dates, album references and other available metadata
remain in `metadata/<object-id>.json` sidecars.

The selected recovery root is restricted to the current user. Files use 0600
permissions and directories use 0700. Recovery files and temporary downloads are
plaintext; use suitable encrypted storage. Allow temporary disk space on the
system temporary volume and destination for large originals. Original transfer
and hashing use bounded chunks, not a whole-video Data buffer. The native S3
transport downloads to a temporary file, followed by verified destination-local
staging and atomic publication. Concurrent downloads default to four and can be
set with `--concurrency 1` through `16`.

The `.attic-restore.json` journal binds the operation to a backup identity and
records each completed key, checksum and size. Keep it with the recovered files.
Repeat the same command to resume. Existing files are rehashed and size-checked;
the journal alone is never proof of completion. Correct files are skipped;
missing files are downloaded again. Different existing bytes are preserved and
reported as conflicts. Attic never automatically deletes unrelated files or
silently replaces a damaged existing original. Choose another recovery directory
or inspect a conflicting file before deliberately removing it yourself.

Known sidecars can be atomically refreshed when metadata or the selected alias
set changes, after validating their backup/key/checksum provenance. Unrelated or
corrupt sidecars and mismatched/corrupt journals are refused. Select a fresh
destination when recovering another backup or a changed original. Symlinks,
hard links, special files, missing/replaced roots and concurrent writers are
rejected using the same local APFS/HFS+ filesystem protections as backup.

A successful exit means all selected file resources were recovered or verified,
and any selected import phase has no failure or uncertainty. Missing/corrupt
objects, conflicts, archive-pending resources and failed/uncertain imports produce
a nonzero exit. Cancellation leaves already published valid files available for
resume. Reports cap failure details; untrusted text is sanitized before display.

## Glacier and Deep Archive

`GLACIER_IR` is immediately readable. Glacier Flexible Retrieval, Deep Archive,
and Intelligent-Tiering archive-access tiers may need a server-side retrieval
before original bytes can be read. Attic inspects HEAD restore/storage headers;
without authorization it reports those resources as pending and exits nonzero.
See the [S3 retrieval API](https://docs.aws.amazon.com/AmazonS3/latest/API/API_RestoreObject.html)
and [HEAD metadata API](https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadObject.html).

```sh
attic restore --profile recovery --destination ~/RecoveredPhotos \
  --request-archive --archive-tier bulk --archive-days 7 --wait-seconds 300
```

`--request-archive` explicitly authorizes potentially chargeable requests. Review
your provider's retrieval and transfer pricing before using it. Standard and Bulk
are supported; Expedited is not. Retention defaults to seven days (1-365 allowed)
and is omitted for Intelligent-Tiering, as required by S3. An already-running
retrieval is polled without submitting a duplicate request. Only the specific
`RestoreAlreadyInProgress` 409 response is accepted as an existing job.

Polling defaults to zero waiting. `--wait-seconds` gives the entire transfer
phase a shared monotonic polling budget, from zero through 86400 seconds, with
at most fifteen seconds between status polls. Network request timeouts apply
separately. When the budget expires, pending resources remain resumable; repeat
the command after retrieval completes. File originals and the backup manifest
remain unchanged; explicitly requested server-side availability is the exception
to otherwise read-only source operation. Non-S3 providers may reject these S3
capabilities and must be validated for their supported storage classes.

## Optional Photos import

File recovery is independent of Photos import. To opt in, select an existing
`.photoslibrary` explicitly and quit Photos before starting:

```sh
attic restore --profile recovery --destination ~/RecoveredPhotos \
  --photos-library ~/Pictures/Recovery.photoslibrary
```

Only verified successful file resources enter the import phase. Attic opens the
selected library without interrupting an existing Photos session, checks the
library identity, and requires that Photos has that sole Photos.sqlite database
open. It rechecks selection before and after every import. If targeting cannot
be verified on the installed macOS/Photos version, import fails safely while the
recovered files remain usable. Do not switch libraries or modify the recovery
files while this optional phase is running. This cooperative constraint is
necessary because the public macOS APIs do not provide atomic arbitrary-library
selection and import as one operation.

Photos handles media import with duplicate checking enabled. This produces new
Photos assets from the recovered file names; it does not reconstruct the original
Photos database, original asset IDs, album layout, favorites, editing history, or
missing Live Photo components. Sidecars preserve available original names and
metadata for inspection or another recovery workflow.

The journal records import intent before sending the event, then stores returned
Photos IDs after confirmation. Completed imports are skipped on resume, including
an import that Photos completed with no new IDs after duplicate checking. A lost
response, timeout, crash or cancellation after intent is uncertain. Attic does
not repeat it automatically. Inspect the selected library first, then use
`--retry-uncertain-imports` only if you deliberately want another attempt.
Duplicate checking remains enabled. The journal is bound to the selected library
identity; choose a new recovery directory to import into a different library.
Permission or preparation failure does not invalidate recovered originals.

## Validation boundaries

Regression tests cover manifest/metadata selection, v1/v2 and cloud IDs, invalid
keys/checksums, corrupt/truncated/missing downloads, independent original keys,
resume/conflict/journal behavior, sidecar refresh, concurrency, cancellation,
source immutability, archive transitions and Photos permission/duplicate/uncertain
orchestration with mocks. A local loopback HTTP fixture exercises the actual
URLSession download-to-file path. Synthetic old/new SQLite album schemas pass
through released Ladder 0.7.0 enrichment, backup to mock S3 and filesystem,
verification, restore and hash checks; the fixture also validates backup JSONL.

No live bucket, chargeable archive request, real Photos library or real Photos
import has been used for validation. In particular, positive library-targeting
behavior of the macOS import adapter remains unverified against a disposable
real Photos library. Physical drive unplug/power-loss behavior is also untested.
These limits must be retained in release/review evidence.
