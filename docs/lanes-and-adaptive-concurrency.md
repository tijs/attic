# Lanes and adaptive concurrency

Attic backs up two very different kinds of photo assets in parallel: ones that
are already on disk, and ones that still live on Apple's servers. Mixing them
in a single pool is a compromise that loses to both extremes, so the exporter
partitions each batch into two **lanes** and runs each at a concurrency limit
suited to its behavior.

## The two kinds of assets

With **"Optimize Mac Storage"** enabled, Photos.app keeps only recent or
frequently-accessed originals on disk. Everything else is a thumbnail-only
placeholder whose original lives in iCloud.

### Local assets

The original file is on disk in the Photos library bundle. Exporting one is
essentially a file copy + inline SHA-256 hash.

- **Fast** — hundreds of MB/s, limited by disk and CPU.
- **Predictable** — no network in the loop.
- **Few failure modes** — "disk full" and "permission denied" are about it.
- **Parallelism helps** — more concurrency, more throughput, up to disk
  saturation.

### iCloud-only assets

Only the thumbnail is on disk. Exporting means asking Photos.app to pull the
original from iCloud, which involves auth, a round-trip to cold storage, and a
write back to local disk.

- **Slow** — network-bound, often seconds per asset.
- **Heavily throttled** — iCloud rate-limits hard if you ask for too many at
  once.
- **Many transient failure modes** — timeouts, `-1712` AppleEvent timeouts,
  503s from iCloud, rate-limit waits.
- **Some permanent failures** — shared-album derivatives that have gone
  missing server-side raise `-1728 "Can't get media item"`. Retrying doesn't
  help.
- **Parallelism past a point hurts** — iCloud starts queuing you, total
  throughput drops.

## Why a single pool is wrong

If you run one pool at a single concurrency limit, you're stuck picking a
number that's wrong for one side:

| Pool size | Local lane | iCloud lane |
|-----------|------------|-------------|
| 16        | great      | throttled into the ground |
| 2         | drip-feed  | safe but slow |

Neither number is right. Splitting the lanes lets each run at its own pace.

## How the split is decided

LadderKit exposes a `LocalAvailabilityProviding` protocol that answers "is
this asset's original on disk?" The real implementation,
`PhotosDatabaseLocalAvailability`, reads one column from Photos.sqlite:

```
ZINTERNALRESOURCE.ZLOCALAVAILABILITY = 1
```

This is the same flag Photos.app itself uses to decide whether to show the
little download-cloud icon in the UI. It's cheap to read and doesn't touch
PhotoKit.

At batch time, `PhotoExporter` partitions every UUID:

- `ZLOCALAVAILABILITY = 1` → **local lane**
- everything else → **iCloud lane**

```
          ┌── local lane    ──→ concurrency = maxConcurrency (e.g. 16)
batch ────┤
          └── iCloud lane   ──→ concurrency = AIMDController.currentLimit()
                                (adapts: 1-12, starts at 6)
```

Each lane has its own `TaskGroup`, its own concurrency cap, and — critically
— its own feedback signals. Congestion on the iCloud side doesn't slow the
local side down.

## The iCloud lane is adaptive

Because iCloud's tolerance shifts minute to minute, picking a fixed iCloud
concurrency is also wrong. The iCloud lane is gated by an **AIMD controller**
(attic's `AIMDController`, implementing LadderKit's
`AdaptiveConcurrencyControlling` protocol).

**AIMD** (Additive Increase, Multiplicative Decrease) is the congestion-control
policy TCP uses. The asymmetry is the point: recover cautiously, back off
hard.

- The controller keeps a **sliding window of the last 20 outcomes**.
- **Transient failure rate > 30%** → halve the limit (floor at `minLimit`).
- **Transient failure rate ≤ 5%** → grow the limit by 1 (cap at `maxLimit`).
- **Window clears on every limit change** — prevents stale pre-change
  outcomes from immediately re-tripping the new limit.

The exporter polls `currentLimit()` between dispatches and reports each
`ExportOutcome` (`.success`, `.transientFailure`, `.permanentFailure`) via
`record(_:)`. The controller is observation-only — it doesn't hold permits or
gate dispatch directly, it just publishes a number the exporter reads.

### Why permanent failures don't affect the limit

A batch full of `-1728` shared-album tombstones isn't a lane-health signal —
the lane is fine, those assets just don't exist anymore. Reporting them as
transient failures would permanently pin the lane at `minLimit`.

Ladder classifies each export error as `.other`, `.transientCloud`, or
`.permanentlyUnavailable` and reports `.permanentFailure` to the controller
for the last category. The controller **ignores `.permanentFailure`** entirely
— it doesn't enter the window, doesn't count toward the rate. Attic also
records permanent-unavailable UUIDs in `unavailable-assets.json` so they're
skipped forever on future runs.

## What this looks like in practice

On a mixed Optimize-Storage library:

```
Backup started — 2,431 assets pending
  Local lane:   1,804 assets  →  running at 16 concurrent
  iCloud lane:    627 assets  →  running at 6 concurrent (adaptive)

[...]

  iCloud lane throttling — limit 6 → 3
  iCloud lane recovering — limit 3 → 4
  iCloud lane recovering — limit 4 → 5
```

- The local lane blasts through cached originals in parallel.
- The iCloud lane ticks along at whatever rate iCloud currently tolerates.
- Failures in one lane don't slow the other down.
- Permanent failures (tombstones) are skipped, not retried, and don't affect
  concurrency tuning.

## Where this lives in the code

| Layer | Type | Where |
|---|---|---|
| Local/iCloud split | `LocalAvailabilityProviding`, `PhotosDatabaseLocalAvailability` | LadderKit |
| Per-lane dispatch | `PhotoExporter` | LadderKit |
| Controller protocol | `AdaptiveConcurrencyControlling`, `ExportOutcome` | LadderKit |
| Error classification | `ExportClassification` | LadderKit |
| AIMD policy | `AIMDController` | `Sources/AtticCore/AIMDController.swift` |
| Permanent-unavailable store | `UnavailableStore` | `Sources/AtticCore/UnavailableAssets.swift` |

LadderKit supplies the **mechanism** (partitioning, protocol, outcome
reporting). AtticCore supplies the **policy** (the actual AIMD controller
implementation, the unavailable store, the backup pipeline). The two
responsibilities are cleanly separated so a different caller could plug in a
different controller (EWMA, PID, token bucket) without touching ladder.
