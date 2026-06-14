# CLAUDE.md

Guidance for working in this repository.

## What this is

**DiskLens** — a personal-use native macOS disk visualizer & cleaner (a DaisyDisk replacement).
Scans a folder/volume/whole disk (with an optional **admin/root** scan), shows where space goes
in six switchable charts, caches every scan as a browsable **run**, lets you **compare** runs, and
cleans up via Trash + a collection bag. SwiftUI + Swift 6, macOS 14+. Personal use — keep it
focused.

## Layout

```
Packages/DiskLensCore/        Pure logic, no UI — fully unit-tested (`swift test`).
  Model/      FileNode, FileTree, RunMetadata, ScanOptions, ScanProgress, NodeFlags
  Scan/       DiskScanner (POSIX walk), ScanCancellation
  Store/      RunStore, TreeCodec, TreePruner, NodeLocator
  Diff/       DiffEngine, TreeDiff/DiffChange
  Layout/     SunburstLayout, TreemapLayout, IcicleLayout   (pure geometry)
App/                          SwiftUI app target "DiskLens"
  Model/      AppModel (@Observable @MainActor), VizKind
  Scan/       ScanCoordinator (background scan → main-actor progress)
  Elevation/  ElevationService + OnDemandElevationService (osascript admin)
  Views/      Sunburst/Treemap/Icicle/ListTable/Bar views, ChartArea, Sidebar, Compare, ChartPalette
  Cleanup/    TrashService, ChartNodeMenu, BagBar
  Settings/   Preferences (UserDefaults), SettingsView
  Support/    Formatting, SnapshotMode
Helper/                       "disklens-helper" CLI — embedded, run as root for admin scans
project.yml                   XcodeGen spec — the single source of truth for the .xcodeproj
```

## How it fits together

- **`DiskLensCore` is UI-free and is the shared engine** for both the app and the privileged
  helper. All algorithmic work (scan accounting, diff, layouts, serialization, path resolution)
  lives here and is unit-tested. The app and helper are thin shells over it.
- **Scanning** reads directory entries with `getattrlistbulk(2)` (one syscall per *batch* of
  entries, not one `lstat` per file — the speed win; an `lstat`/`opendir` path remains as a
  fallback for filesystems without bulk support, forced via `DISKLENS_NO_BULK`). Size is
  `ATTR_FILE_ALLOCSIZE` ≈ `st_blocks * 512` (matches `du`): hard-link dedupe by `(dev,ino)`,
  symlinks flagged not followed, stops at volume boundaries. The root's child subtrees are walked
  **in parallel** (`DispatchQueue.concurrentPerform`) sharing one lock-guarded inode set, so
  dedupe stays exact; per-subtree stats merge at the end. Runs off the main actor via
  `ScanCoordinator`; the finished `FileTree` is immutable & `Sendable`.
- **Admin scan**: the app launches the bundled `disklens-helper` as root via
  `osascript … with administrator privileges`, polling a side file for progress (the auth prompt
  blocks until done). The helper `chmod 0644`s its outputs so the launching user can read
  root-written files. `ElevationService` is the seam for a future `SMAppService` daemon.
- **Runs**: `RunStore` keeps a JSON index + one zlib-compressed tree blob per run in
  `~/Library/Application Support/DiskLens`, capped by `maxRuns`. Large blobs are decoded **off the
  main actor** (`AppModel.select`), so launch never blocks.
- **Cleanup**: `NodeLocator` reconstructs a node's absolute path (FileNodes store only names) —
  **safety-critical**, so it's unit-tested. Deletes go to the Trash, then `TreePruner` updates the
  in-memory tree so the chart reflects the change without a rescan.
- **Diff**: `DiffEngine` matches two trees by name, yielding a changes list + summary + a
  per-current-node delta map that tints the charts (`colorOverride`).

## Conventions & gotchas

- **XcodeGen**: the `.xcodeproj` is generated and gitignored. **Run `xcodegen generate` after
  adding/removing/renaming any source file** — the file list is static, not synchronized. Generated
  `App/Info.plist` and `App/DiskLens.entitlements` are also gitignored.
- **`DiskScanner`, not `Scanner`** — `Foundation.Scanner` shadows the name; the type is
  `DiskScanner`.
- **Non-sandboxed** app (required to scan the whole disk). Full Disk Access (a TCC grant) gives
  fuller non-admin coverage; the FDA banner nudges toward it when a scan hits many unreadable dirs.
- **Snapshot verification**: `--snapshot <dir>` renders the active run's charts to PNG via
  `ImageRenderer` (no Screen Recording permission needed). **`Table`-based views (list, changes
  inspector) can't be captured by `ImageRenderer`** — they render only in the live window.
- TDD for everything in `DiskLensCore`: write the failing test first (`swift test`), then implement.
- **App icon** is a generated sunburst (`App/Assets.xcassets/AppIcon.appiconset`). It's rendered
  by `scripts/make-icon.swift` (CoreGraphics, reuses the `ChartPalette` hues) and downscaled to all
  macOS sizes by `scripts/make-icon.sh` — edit the renderer and rerun the script to change it; the
  `.appiconset` `Contents.json` is hand-maintained.

## Build & test

```sh
xcodegen generate                                   # regenerate the project (after file changes)
cd Packages/DiskLensCore && swift test              # fast core unit tests
xcodebuild -scheme DiskLens -destination 'platform=macOS' build   # +CODE_SIGNING_ALLOWED=NO unsigned
xcodebuild -scheme DiskLens -destination 'platform=macOS,name=My Mac' test   # app tests (DiskLensTests)
open DiskLens.xcodeproj                              # or just open it
```

- **App-target tests** live in `Tests/` (`DiskLensTests`, hosted in the app for `@testable import`).
  They render SwiftUI views offscreen with `ImageRenderer` and inspect pixels — the way to catch
  "renders but invisible" view bugs that pure-logic tests can't (e.g. `ChartTooltipTests`).

## Known follow-ups

- Admin elevation re-prompts each scan; a persistent `SMAppService` helper (Developer-ID signed)
  would remove the prompt and enable scheduled background scans.
- Quick Look (spacebar preview) isn't wired yet.
