# Filesystem backups

Issue: https://github.com/tijs/attic/issues/4

Attic can back up to a directory on a local APFS or HFS+ volume, including an
external drive. Each run selects one destination. S3 remains the default for
existing configurations.

## Set up a destination

Mount the drive and create an empty directory on it. Attic never creates a
missing destination root, including during initialization. For example:

```sh
mkdir /Volumes/PhotoBackup/Attic
attic init --filesystem /Volumes/PhotoBackup/Attic --profile external
attic backup --profile external
attic status --profile external --json
attic verify --profile external
```

`init --filesystem` uses no S3 credentials or Keychain prompts. It writes a
private `.attic-target.json` identity marker in the selected directory and saves
its identity in `~/.attic/profiles/external/config.json`. New destination
permissions are restricted to the current user (0700 directories, 0600 files).
Photo originals and metadata remain plaintext; use an encrypted volume when
needed. Photos and Automation permissions for exporting originals still apply.

An existing configured profile is never overwritten by `init`. Use a new
`--profile` to select another destination. The same flag works on `backup`,
`status`, `verify`, `refresh-metadata`, `rebuild`, and `migrate` (the last command
reports that S3 migrations are not supported for filesystem targets).

Without `--profile`, Attic keeps using `~/.attic/config.json`. Existing S3 JSON
configuration remains valid. A filesystem config is selected by its `filesystem`
object, containing `path`, `targetID`, `volumeUUID` and `rootInode`. Let `init`
create these values; copying an identity marker to another directory does not
make that directory the same destination.

## Independent target state

Each destination has its own manifest and metadata. Filesystem retry,
unavailable-asset, and export-staging state is stored under the profile's
`targets/<targetID>/` directory. Named S3 profiles use a fingerprint of endpoint,
region, bucket and URL style, so changing a target cannot reuse another target's
skip/retry state. Existing default-profile S3 state is bound once to the current
endpoint/bucket and retained in its old location; subsequent target changes get
a separate state directory. Use profiles when changing targets, rather than
editing an old installation's configuration before its first upgraded run.

Fresh filesystem targets start with a v2 cloud-identity manifest. They never
import an unrelated legacy `~/.attic/manifest.json`. `migrate` and `--repair`
remain S3-only. Filesystem `rebuild` scans that target's metadata and saves a new
manifest there; `verify` checks object existence, just as it does for S3. It does
not claim a full-media checksum audit. Original checksums are verified during
filesystem publication and available to recovery tools.

`status --json` retains the existing S3 schema for S3 targets. Filesystem targets
instead expose `filesystem: {path, manifestEntries, lastBackupAt?}`. The library,
backup, retry and type sections keep their existing meanings. `backup --json`
uses the same JSONL progress contract for both destinations.

## Missing drives, locking and writes

Attic binds the target to its volume UUID, root directory inode, and random
target ID. It verifies these before object operations and checks the root path
again before and after atomic publication. A `/Volumes/<name>/...` target must
actually reside on that named mounted volume; a stale directory on the internal
disk is rejected. Missing or replaced roots fail, and Attic never creates a
replacement root on the internal disk. Unplugging a drive aborts writes; reconnect
it and repeat the command.

All filesystem commands take an exclusive nonblocking advisory lock for the
lifetime of their object store, including readers. A second command fails clearly
instead of observing a partially updated target. The lock is released by the OS
when the process exits; a leftover `.attic-writer.lock` file is harmless and
should not be removed to bypass an active writer.

Paths are resolved with descriptor-relative operations that reject symlinks,
hard links, special files and nested mount points. Original data is copied in
1 MiB chunks to a destination-local staging file, checked against the export's
SHA-256 and size, synchronized, and atomically published. Metadata and the
manifest are replaced atomically after originals are complete. A preexisting
original is accepted only when its full size and checksum agree; different bytes
are never overwritten. A failed or cancelled write cannot create a durable
manifest entry for an incomplete original.

The object layout follows the S3 logical key hierarchy (`originals/`,
`metadata/assets/`, `manifest.json`). Physical path components reversibly escape
uppercase ASCII, percent signs and leading dots so case-sensitive object identities remain
distinct on ordinary case-insensitive APFS/HFS+ volumes. The manifest and metadata
retain the logical keys. Access objects through Attic's storage interface; do not
copy this directory blindly into an S3 bucket and assume physical filenames are
identical to S3 keys. Components that exceed the filesystem's 255-byte name limit
after escaping fail clearly, without publishing an original.

Interrupted processes may leave hidden `.attic-part-<UUID>` staging files. They
are ignored by listing/rebuild and never treated as completed originals. They
may be removed to recover disk space while no Attic command is using the target.
Export staging inside the private profile is reused on the next run when safe.

## Recovery and limits

If a drive or directory is intentionally renamed, use `init --filesystem` with a
new profile pointing at the existing target. It accepts only the same volume,
root inode and target ID and binds the new local path without rewriting backup
objects. An older config keeps failing safely at its old path. Preserve the
identity marker when moving a complete target; copying data to a different
volume is a separate migration and requires a deliberate new destination.

Only local APFS and HFS+ are supported by this version. SMB, NFS, cloud-mounted
filesystems, FAT/exFAT, symlinked object trees and nested mounts do not have the
required guarantees here and are rejected. Advisory locking assumes other tools
and the same user do not modify the managed directory during a run. `fsync` and
atomic rename provide the OS filesystem guarantees, not immunity from hardware
failure or corruption. Keep another independent backup.

Validation uses disposable directories and synthetic exports only. Regression
tests simulate root replacement/disconnection, wrong mount metadata, read-only
permissions, ENOSPC, cancellation, lock contention and crash-style leftover lock
files; they also run backup, repeat, verify, metadata refresh and rebuild with
cloud IDs and equal original filenames. A physical drive unplug and power-loss
experiment have not been performed. No live Photos library or S3 bucket is used.
