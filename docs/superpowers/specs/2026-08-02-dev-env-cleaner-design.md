# Dev Environment Cleaner — Design

Date: 2026-08-02
Status: Approved, not yet implemented
Scope: Stray v1.1 — first disk-reclaim feature

## Problem

The machine runs at 89% full (382 GB used, 47 GB free on a 460 GB SSD). Cleaning is done
by hand today: remember which caches exist, `du` them, `rm -rf` the big ones, repeat every
few weeks. Measured on 2026-08-02, roughly 61 GB is sitting in regenerable developer
artifacts — more than the free space remaining.

| Target | Measured size |
|---|---|
| `node_modules` under `~/Development` (55 dirs) | 23.2 GB |
| `~/Library/Developer/CoreSimulator/Devices` | 16 GB |
| `~/Library/pnpm` | 9.2 GB |
| `~/.yarn-cache` | 5.5 GB |
| `~/Library/Developer/Xcode/DerivedData` | 5.4 GB |
| `~/.npm` | 3.2 GB |
| `~/.cache` | 2.6 GB |
| `~/.bun/install/cache` | 1.1 GB |
| `~/.gradle` | 616 MB |

Stray already owns the "find waste, show evidence, act with confirmation" shape for
processes. Disk reclaim is the same shape against a different substrate.

## Scan cost, measured

- Whole-home walk with exclusions, pruning at first match: **2.3 s**, 7,872 hits.
- Of those hits, **72 live in visible directories** (71 under `~/Development`, 1 under
  `~/Documents`). The remaining ~7,800 live inside dot-caches: 4,409 in `~/.yarn-cache`,
  2,231 in `~/.lmstudio`, plus `~/.cache` and `~/.pyenv`.
- Sizing 55 `node_modules` with `du` took **26 s**.

Two conclusions drive the design. Discovery is cheap and sizing is expensive, so they must
be separate phases. And a raw whole-home walk is unusable as a findings list — the dot-cache
hits must collapse into one row per cache, not 4,409 rows.

## Non-goals for v1

Duplicate file detection. Scheduled or background disk scans. Size history or trend charts.
`/Library` or system-level caches (needs a privileged helper, deferred with the v2 launchd
work). Deleting configured simulator devices or any user data.

## Architecture

New directory `Stray/Core/Disk/` with four files, each with one responsibility.

### `CacheCatalog.swift`

The curated table of known cache locations. This is where product value lives, the same way
`Rules.swift` holds it for processes: adding a newly discovered cache is one struct literal,
no new code paths.

```swift
struct CacheEntry {
    let id: String              // stable key, e.g. "xcode.derived-data"
    let name: String            // "Xcode DerivedData"
    let paths: [URL]            // one or more roots
    let reclaim: ReclaimMethod  // .trash, .simctlDeleteUnavailable, .dockerImagePrune
    let regeneratedBy: String   // "Rebuilding in Xcode" — shown as the finding's evidence
}

enum ReclaimMethod { case trash, simctlDeleteUnavailable, dockerImagePrune }
```

v1 entries, grouped:

- **Package manager stores** — `~/.yarn-cache`, `~/Library/pnpm`, `~/.npm`,
  `~/.bun/install/cache`, `~/.gradle`, `~/Library/Caches/CocoaPods`. All `.trash`.
- **Xcode artifacts** — `DerivedData`, `Archives`, `iOS DeviceSupport` via `.trash`;
  `CoreSimulator/Devices` via `.simctlDeleteUnavailable`.
- **Allowlisted generic caches** — `~/.cache`, and inside `~/Library/Caches` only:
  `Homebrew`, `CocoaPods`, `Yarn`, `pip`, `ms-playwright`. All `.trash`.
- **Docker** — `.dockerImagePrune`. Entry is hidden when the `docker` CLI is absent.

Explicitly excluded, and the reason this is a curated table rather than a pattern match:
`~/.pyenv` (426 MB), `~/.local` (1.3 GB), `~/.platformio` (2.4 GB) and `~/.lmstudio`
(1.8 GB) all match cache-shaped heuristics but are installed tooling and downloaded model
weights. Deleting them costs hours, not a rebuild.

### `DiskScanner.swift`

Walks the home directory for project junk. Uses `FileManager.enumerator` with
`.skipsPackageDescendants`, and calls `skipDescendants()` on the first match so nested hits
never enumerate.

Hidden directories are **not** skipped via `.skipsHiddenFiles` — that option would also hide
`.next` and `.venv`, which are targets. Instead the walk skips any directory whose name
starts with `.` unless that name is in the match list. This is what keeps the ~7,800
dot-cache hits out of the project list while still catching `.next` and `.venv` inside
visible projects.

Match rules — some names are too generic to trash on the name alone, so those require a
sibling marker file in the parent directory:

| Directory | Required sibling marker |
|---|---|
| `node_modules` | none |
| `.next` | none |
| `Pods` | `Podfile` |
| `.venv` | none |
| `__pycache__` | none |
| `build` | `build.gradle`, `build.gradle.kts`, or `CMakeLists.txt` |
| `target` | `Cargo.toml` or `pom.xml` |

Without the marker requirement, `build` and `target` match ordinary source directories —
a `src/build/` holding hand-written code would be offered for deletion.

Top-level exclusions: `Library`, `Pictures`, `Movies`, `Music`, `Applications`, `.Trash`,
and any `*.photoslibrary` bundle.

Returns `[URL]` only. No sizing, no `Finding` construction — that belongs to the engine.

### `SizeProbe.swift`

Computes allocated size for a URL by recursive enumeration reading
`.totalFileAllocatedSizeKey`. Never resolves symlinks: `~/Library/pnpm` and the yarn store
are symlink farms, and following them both double-counts and would let a later delete escape
the intended tree.

Runs at most 4 concurrent probes so a scan does not saturate SSD I/O. Emits results per path
as each completes, so the UI can fill rows progressively.

### `Reclaimer.swift`

The only code in the app that deletes. Every method routes through one guard:

```swift
static func assertSafe(_ url: URL) throws
```

which rejects any path that is not under `$HOME`, is `$HOME` itself, is an ancestor of a
configured scan root, or resolves outside `$HOME` once symlinks are resolved.

- `trash(url)` — `FileManager.trashItem`, after the guard.
- `simctlDeleteUnavailable()` — `xcrun simctl delete unavailable`. Removes orphaned
  simulator runtimes only; configured devices are user data and are left alone.
- `dockerImagePrune()` — `docker image prune -f`. Dangling images only. Never
  `docker system prune -a`, which removes named volumes.

## Model changes

`Finding` gains:

```swift
var bytes: Int64?    // nil while sizing is in flight
```

and `FindingKind` gains `.projectJunk` and `.toolCache`. Disk findings carry `pid: nil`, the
same way launchd findings already do. No parallel model type — the existing row view already
renders title, evidence, timestamp and an action button, which is exactly what a disk finding
needs.

`ScanEngine` gains:

```swift
@Published var diskFindings: [Finding] = []
@Published var isDiskScanning = false
@Published var trashBytes: Int64?
func scanDisk()
func emptyTrash()
```

Disk state stays separate from `findings` so the existing 5-minute process timer never
touches it. Disk scans are manual only.

## Data flow

1. User clicks **Scan disk**.
2. `DiskScanner.scan()` returns project junk URLs (~2 s). `CacheCatalog.present()` filters
   the catalog to entries whose paths exist. Both are mapped to `Finding`s with `bytes: nil`
   and published immediately — the list is usable at this point.
3. `SizeProbe` starts, 4 at a time. Each completion updates that finding's `bytes` on the
   main actor. The header total climbs live.
4. Once sizing completes, rows re-sort by size descending.
5. User confirms a row. `ScanEngine.resolve` dispatches on `kind` to `Reclaimer`, then
   refreshes `trashBytes` and drops the row.

## UI

The panel gets two sections under the existing header: **Processes** (unchanged) and
**Disk**. Disk renders a `Scan disk` button until the first scan, then a findings list.

- Section header shows `Reclaimable: 31.4 GB`, updating as sizes arrive.
- Rows show size where known and `—` while pending.
- A project whose own files were modified in the last 7 days shows an amber `active` chip.
  Still deletable — the two-step confirm is the gate — but visually distinct so today's
  project is not trashed by a mis-click.
- Footer gains `Trash: 18 GB · Empty`. Trash-only deletion means space is not returned until
  the Trash is emptied; surfacing it here keeps that one click deliberate rather than
  invisible.

All strings in English, matching the rest of the app.

## Error handling

Failures are per-row and never abort a scan. A path that disappears between scan and delete
is dropped silently (the goal was its absence). A `trashItem` failure — permissions, or a
file in use — leaves the row in place and marks it failed rather than silently vanishing.
`simctl` and `docker` are subprocesses: non-zero exit surfaces as a failed row, and a missing
binary means the entry never appears in the first place.

## Testing

The repo has no test target today. This adds one narrow target covering pure logic, no
filesystem writes:

- `Reclaimer.assertSafe` — rejects `/`, `$HOME`, `..` traversal, symlinks pointing outside
  `$HOME`, and scan-root ancestors; accepts a normal `node_modules` path.
- `DiskScanner` match rules — `build` next to `build.gradle` matches, `build` next to
  nothing does not; `target` next to `Cargo.toml` matches, a bare `target` does not.
- `CacheCatalog` — every entry has a non-empty id, name and at least one path; ids are
  unique; no entry path is `$HOME` or a bare top-level system directory.

Everything else — the walk, sizing accuracy, progressive UI — is verified by running the app
against the real disk, consistent with how the process rules were verified.

## Open follow-ups (not this spec)

Parent/child dedupe across process rules (an `npm exec X` parent and its `node .../X` child
are counted as two duplicates today). Duplicate file detection. A privileged helper for
`/Library` caches.
