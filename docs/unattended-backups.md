# Unattended backups on macOS

Run `attic backup` automatically on a daily schedule on a Mac mini, an
always-on iMac, or any Mac that stays logged in. This guide assumes you have
already run `attic init` once (see the [README](../README.md)) so that
`~/.attic/config.json` exists and your S3 credentials are stored in the
keychain.

## TL;DR

1. Run a small interactive backup once to grant Photos access and trust the
   keychain.
2. Drop a LaunchAgent plist into `~/Library/LaunchAgents/`.
3. Schedule a wake-from-sleep five minutes before the backup window.
4. Tail the log to confirm the next run uploads.

The full version below takes about 10 minutes.

## Prerequisites

- macOS 14+ (Sonoma) on Apple Silicon
- `attic` installed (`brew install tijs/tap/attic`)
- `attic init` completed — config file present at `~/.attic/config.json`,
  S3 access/secret stored in the login keychain
- The Mac stays logged in to a single user account when scheduled runs fire.
  Lid closed, display asleep, no terminal open — all fine. Only logout or
  shutdown breaks the schedule.

## 1. Prime macOS permissions (do this once, in a real terminal)

macOS gates two things behind first-launch prompts: Photos library access
(TCC) and keychain reads. Both prompts can only be answered by a human
clicking a dialog, so run a small backup interactively first to get them out
of the way:

```bash
attic backup --limit 1
```

You'll see up to two prompt classes:

- **Photos** — "attic would like to access your Photos library." Click
  *Allow*. Recorded in System Settings → Privacy & Security → Photos.
- **Keychain** — "attic wants to use your confidential information stored in
  'attic-s3-access-key' in your keychain." Click **Always Allow** (not just
  *Allow*). Repeat for `attic-s3-secret-key`. *Always Allow* writes a
  trusted-app entry into the keychain item's ACL so future invocations of
  the same binary skip the prompt — including invocations spawned by launchd
  in the background.

Confirm the prompts are gone:

```bash
attic status                # should print library + S3 stats with no prompts
attic backup --limit 5      # should run silently
```

If the second `attic backup` still prompts for keychain, open Keychain
Access, find the `attic-s3-access-key` and `attic-s3-secret-key` items, edit
*Access Control*, and add `/opt/homebrew/bin/attic` to the always-allow list.

## 2. Install the LaunchAgent

Create the log directory and the plist in one shot. The heredoc below writes
a working plist for the **current user** — `$USER` and `$HOME` expand at
write time, so you can copy this verbatim:

```bash
mkdir -p ~/Library/LaunchAgents ~/Library/Logs/attic

cat > ~/Library/LaunchAgents/org.tijs.attic.backup.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>org.tijs.attic.backup</string>

    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/attic</string>
        <string>backup</string>
        <string>--limit</string>
        <string>2000</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>3</integer>
        <key>Minute</key><integer>0</integer>
    </dict>

    <key>RunAtLoad</key><false/>
    <key>ProcessType</key><string>Background</string>
    <key>LowPriorityIO</key><true/>
    <key>Nice</key><integer>5</integer>

    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/attic/backup.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/attic/backup.log</string>
</dict>
</plist>
EOF

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.tijs.attic.backup.plist
```

Verify the agent is loaded:

```bash
launchctl print gui/$(id -u)/org.tijs.attic.backup | head -20
```

Look for `state = not running` and `program = /opt/homebrew/bin/attic`.

### About `--limit 2000`

Without `--limit`, attic drains every pending asset on each run. A first-time
catch-up over a large iCloud library can take many hours — fine if you don't
mind, surprising if you do. Capping each run keeps wall-clock predictable:

- 2000 assets ≈ 1–2 hours, depending on how many are videos and how many are
  iCloud-only (the iCloud lane is rate-limited adaptively).
- The cap is per-run, not per-day; nothing is lost. The next run picks up the
  remainder.
- Set higher (or remove) once you're caught up — daily deltas from a phone
  are typically tens to a few hundred assets and finish in minutes.

A copy of this plist also lives at
[`examples/org.tijs.attic.backup.plist`](../examples/org.tijs.attic.backup.plist)
in the repo.

## 3. Schedule a wake-from-sleep (recommended)

A sleeping Mac will not fire scheduled launchd jobs. On a Mac that's not
already kept awake by something else, schedule a daily wake five minutes
before the backup window:

```bash
sudo pmset repeat wakeorpoweron MTWRFSU 02:55:00
pmset -g sched          # verify
```

Adjust the time if you change `StartCalendarInterval` in the plist.

## 4. Smoke-test it

You don't have to wait for 03:00 to confirm everything works. Kick the agent
once on demand and tail the log:

```bash
launchctl kickstart -k gui/$(id -u)/org.tijs.attic.backup
tail -F ~/Library/Logs/attic/backup.log
```

A healthy run looks like:

```
Starting backup: 2000 assets (1812 photos, 188 videos)
Batch 1/40 (50 assets)
  → IMG_1234.HEIC (842.1 KB)
  ✓ IMG_1234.HEIC (842.1 KB)
  ...
  Manifest saved (29243 entries)
Backup complete: 2000 uploaded, 0 failed (3.4 GB)
```

If you instead see `Failed to read keychain item`, jump to *Brew upgrade
re-prompts the keychain* below. If you see `Backup complete: 0 uploaded, 0
failed (0 B)` and you know there are pending assets, the launchd-spawned
process is missing Photos access — re-run step 1 in a real terminal, click
*Allow* on the Photos prompt, then kickstart again.

## 5. Set auto-login (so reboots don't break it)

Power outage or kernel panic = reboot. Without auto-login, the Mac sits at
the login window with no user session, and your LaunchAgent is unloaded
entirely. Enable in *System Settings → Users & Groups → Automatically log
in as*.

On Apple Silicon, auto-login coexists with FileVault: the Secure Enclave
unlocks the volume at boot, then macOS signs the user in without prompting
for a password. No special configuration required.

## Adding a periodic verify (optional)

A second LaunchAgent running `attic verify` weekly is cheap insurance — it
re-checks every backed-up object's existence on S3 against the manifest:

```bash
cat > ~/Library/LaunchAgents/org.tijs.attic.verify.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>org.tijs.attic.verify</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/attic</string>
        <string>verify</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key><integer>0</integer>
        <key>Hour</key><integer>4</integer>
        <key>Minute</key><integer>0</integer>
    </dict>
    <key>RunAtLoad</key><false/>
    <key>StandardOutPath</key><string>${HOME}/Library/Logs/attic/verify.log</string>
    <key>StandardErrorPath</key><string>${HOME}/Library/Logs/attic/verify.log</string>
</dict>
</plist>
EOF

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.tijs.attic.verify.plist
```

Sunday at 04:00, in this example, separate log file.

## Gotchas

### Brew upgrade re-prompts the keychain

`brew upgrade attic` replaces the binary at `/opt/homebrew/bin/attic`. The
shipped binary is ad-hoc, linker-signed, so its keychain *Designated
Requirement* is derived from its content hash rather than from a stable
Team ID. Each release looks like a different application to the keychain,
and the existing ACL refuses access until you re-trust it. Symptoms in the
log: `Failed to read keychain item` and a run that does nothing.

Fix: after each `brew upgrade attic`, run `attic status` interactively once,
click *Always Allow* on the prompt, and repeat for the second service.

```bash
grep -E "Failed to read keychain item" ~/Library/Logs/attic/backup.log
```

### TCC re-prompts after upgrade

Less common, but possible. If a backup run reports "0 uploaded" right after
an upgrade and you know the library has pending assets, open System Settings
→ Privacy & Security → Photos, confirm `attic` is still toggled on, and
re-run interactively to clear any stale grant.

### Run drifted past midnight

`attic backup` is idempotent — it skips assets already in the manifest and
resumes failed ones via the local retry queue. A missed day costs nothing;
the next run picks up the slack.

### Log file appears empty for minutes after start

In `1.0.0-beta.20` and earlier, `attic` block-buffered stdout when launchd
captured it, so log lines only flushed every ~4 KB. The agent was running,
just silent. From `1.0.0-beta.21` onward `attic` calls `setlinebuf(stdout)`
on the non-TTY path and lines appear in real time.

If you're on an older build, `tail -F` still works — output just arrives in
chunks.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/org.tijs.attic.backup
rm ~/Library/LaunchAgents/org.tijs.attic.backup.plist
sudo pmset repeat cancel    # if you scheduled a wake
```

`~/.attic/` (config + retry queue + staging) and `~/Library/Logs/attic/` are
left in place. Remove manually if you want a clean slate.

## Why a LaunchAgent and not a Daemon or cron

Three runtime requirements drive the choice:

1. **Login keychain** — only unlocked inside a logged-in user's session.
2. **Photos TCC** — granted per-user, enforced against the calling binary's
   code-signature.
3. **Long-lived adaptive concurrency** — the AIMD controller in attic needs
   to react to PhotoKit/network feedback over the full duration of a run, so
   a one-shot batch executor isn't a great fit.

Implications:

- A **LaunchDaemon** runs as `root` outside any user session: no user
  keychain, no Photos TCC, no PhotoKit. Not viable.
- **cron** runs in a stripped-down user context without an Aqua session;
  TCC and keychain ACL prompts behave unreliably across macOS versions.
- A per-user **LaunchAgent** in `~/Library/LaunchAgents/` is the right shape:
  it inherits the logged-in user's session, has full keychain and TCC access,
  and launchd handles redirection of stdout/stderr to a log file.
