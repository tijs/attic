# Unattended Backups

Run attic on a schedule so your iCloud Photos library is continuously backed up
without manual intervention. This guide covers setup using macOS launchd.

## Prerequisites

Before setting up unattended backups, make sure:

1. `attic init` has been run and works interactively (`attic backup --limit 1`)
2. Both `attic` and `ladder` are installed via Homebrew (`brew install tijs/tap/attic`)
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

Replace `YOU` with your macOS username, then load it:

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

```bash
# Most recent backup output
cat ~/.attic/logs/backup.log

# Errors only
cat ~/.attic/logs/backup-error.log
```

Log files are overwritten each run by launchd. If you need history, consider
redirecting through a script that appends with timestamps:

```bash
#!/bin/bash
/opt/homebrew/bin/attic backup 2>&1 | while IFS= read -r line; do
  echo "$(date '+%Y-%m-%d %H:%M:%S') $line"
done >> ~/.attic/logs/backup.log
```

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

- **Dedicated Mac**: A Mac mini signed into iCloud Photos makes a good
  always-on backup machine. Enable "Prevent automatic sleeping" in System
  Settings > Energy.
- **Network**: Backups need a stable internet connection. If uploads fail, the
  next run picks up where it left off.
- **Disk space**: Attic stages files temporarily in `~/.attic/staging/` during
  export. Make sure there's enough free space for a batch (default 50 assets).
- **iCloud-only assets**: If most of your library is iCloud-only, the first
  backup will download everything from iCloud. This can be slow on the initial
  run.
