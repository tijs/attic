# Unattended Backups

Run attic on a schedule so your iCloud Photos library is continuously backed up
without manual intervention. This guide covers setup using macOS launchd.

## Prerequisites

Before setting up unattended backups, make sure:

1. `attic init` has been run and works interactively (`attic backup --limit 1`)
2. Both `attic` and `ladder` are installed via Homebrew
   (`brew install tijs/tap/attic`)
3. The Mac is signed into iCloud with Photos enabled

## Full Disk Access

Attic and ladder need to read Photos.sqlite and access the Photos library via
PhotoKit. macOS requires Full Disk Access for this.

Open **System Settings > Privacy & Security > Full Disk Access** and enable it
for both:

- `/opt/homebrew/bin/attic`
- `/opt/homebrew/bin/ladder`

If you skip this, backups will fail with a permission error when trying to read
the Photos database.

## Automation permission (for iCloud-only assets)

When "Optimize Mac Storage" is enabled, some assets exist only in iCloud and are
invisible to PhotoKit. Ladder uses an AppleScript fallback via Photos.app to
export these. This requires **Automation permission**.

Open **System Settings > Privacy & Security > Automation** and grant
`/opt/homebrew/bin/ladder` access to **Photos**.

The easiest way to trigger the permission prompt is to run a test backup
interactively:

```bash
attic backup --limit 1
```

If the permission is missing, attic will show a clear error message and abort
before doing any work. For unattended LaunchAgent runs, the permission must be
granted interactively once beforehand.

## LaunchAgent setup

Create a LaunchAgent plist that runs `attic backup` daily.

```bash
mkdir -p ~/.attic/logs
cat > ~/Library/LaunchAgents/photos.attic.backup.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>photos.attic.backup</string>

  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/attic</string>
    <string>backup</string>
    <string>--quiet</string>
    <string>--log</string>
    <string>/Users/YOU/.attic/logs/backup.jsonl</string>
    <string>--notify</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>3</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>/Users/YOU/.attic/logs/backup.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/YOU/.attic/logs/backup-error.log</string>

  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
EOF
```

Replace `YOU` with your macOS username.

The flags used:

- `--quiet` suppresses interactive progress output (spinners, per-asset lines)
- `--log` appends structured JSONL to a file — one JSON object per line with
  events like `start`, `uploaded`, `error`, and `complete`
- `--notify` sends a macOS notification when the backup finishes (or fails)

Load the agent:

```bash
launchctl load ~/Library/LaunchAgents/photos.attic.backup.plist
```

The backup will now run daily at 3 AM. To change the schedule, edit the
`StartCalendarInterval` section and reload:

```bash
launchctl unload ~/Library/LaunchAgents/photos.attic.backup.plist
launchctl load ~/Library/LaunchAgents/photos.attic.backup.plist
```

## Optional: weekly verification

Add a second LaunchAgent that runs `attic verify` weekly to check backup
integrity.

```bash
cat > ~/Library/LaunchAgents/photos.attic.verify.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>photos.attic.verify</string>

  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/attic</string>
    <string>verify</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>0</integer>
    <key>Hour</key>
    <integer>4</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>/Users/YOU/.attic/logs/verify.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/YOU/.attic/logs/verify-error.log</string>

  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
EOF
```

Same drill — replace `YOU`, then `launchctl load` it.

## Checking logs

The JSONL log (`backup.jsonl`) is the best way to review backup history. Each
line is a self-contained JSON object:

```bash
# Last run summary
tail -1 ~/.attic/logs/backup.jsonl | python3 -m json.tool

# All errors
grep '"event":"error"' ~/.attic/logs/backup.jsonl

# Count uploads per run
grep '"event":"complete"' ~/.attic/logs/backup.jsonl
```

Example log entries:

```jsonl
{"event":"start","pending":100,"photos":94,"videos":6,"timestamp":"2025-03-13T03:00:01.000Z"}
{"event":"uploaded","uuid":"ABC123","filename":"IMG_0001.HEIC","type":"photo","size":1048576,"timestamp":"..."}
{"event":"error","uuid":"DEF456","message":"Upload failed","timestamp":"..."}
{"event":"complete","uploaded":99,"failed":1,"totalBytes":52428800,"timestamp":"..."}
```

The JSONL file is appended to (not overwritten), so it accumulates history
across runs.

launchd also captures stdout/stderr to `backup.log` and `backup-error.log`, but
these are overwritten each run.

## Checking status

To see if backups are running and how far along they are:

```bash
# How many assets are backed up vs pending
attic status

# Check if the LaunchAgent is loaded
launchctl list | grep attic
```

## Stopping scheduled backups

```bash
launchctl unload ~/Library/LaunchAgents/photos.attic.backup.plist
launchctl unload ~/Library/LaunchAgents/photos.attic.verify.plist
rm ~/Library/LaunchAgents/photos.attic.backup.plist
rm ~/Library/LaunchAgents/photos.attic.verify.plist
```

## Tips

- **Dedicated Mac**: A Mac mini signed into iCloud Photos makes a good always-on
  backup machine. Enable "Prevent automatic sleeping" in System Settings >
  Energy.
- **Network**: Backups need a stable internet connection. If uploads fail, the
  next run picks up where it left off.
- **Disk space**: Attic stages files temporarily in `~/.attic/staging/` during
  export. Make sure there's enough free space for a batch (default 50 assets).
- **iCloud-only assets**: Assets that only exist in iCloud are exported via
  AppleScript fallback (one at a time, sequentially). This is slower than the
  normal PhotoKit path since each asset is downloaded from iCloud. The first
  backup of a large iCloud-only library may take a while.
