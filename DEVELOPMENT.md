# DEVELOPMENT.md

Working notes for picking DiskLens back up later. `CLAUDE.md` is the architecture
reference (how the pieces fit, conventions, external behavior); **this file is the
"where we are / what's next / how to iterate safely" companion.** Read CLAUDE.md
for the *what*, this for the *next*.

_Last updated: 2026-06-14._

---

## Current status

Feature-complete **v1**. Milestones M1–M8 are all done and committed.

- **Core engine** (`DiskLensCore`): scanner, run store + codec, tree pruner, diff
  engine, sunburst/treemap/icicle layouts, node locator. **47 unit tests, green.**
- **App** (SwiftUI): sidebar with scan buttons + run history, 6 switchable charts
  (sunburst, pie, treemap, icicle, list/table, bar), drill/breadcrumb/hover,
  a cursor-following **hover tooltip** on every interactive chart (sunburst/pie/treemap/icicle/bar —
  `ChartTooltip.swift`; the list view shows columns), a **zoom in/out transition** when changing
  focus (`ChartContent` re-`id`s on `focus` + `.transition`; nav methods wrap the change in
  `withAnimation`), a **Back button + ⌘[** in the breadcrumb bar (plus clickable crumbs and the
  sunburst centre-hole), cleanup (reveal / collect into a bag / move to Trash), compare/diff with
  baseline picker + changes inspector + delta tinting, settings, FDA banner, and a
  **System/Light/Dark appearance** picker (`AppAppearance`, ships **Dark** by default, applied via
  `.preferredColorScheme` on the main + settings windows).
- **Helper** (`disklens-helper`): embedded CLI, run as root for admin scans via
  on-demand `osascript` auth. **Scans only — it has no delete capability.**
- Builds clean (`xcodebuild -scheme DiskLens`), unsigned is fine for personal use.

**Verified working:** scanner totals match `du -s`; all charts render (confirmed
via headless snapshot PNGs); cleanup resolve→trash→prune end-to-end; diff
classification + tinting; admin plumbing (osascript → root helper → 0644 blob +
progress polling).

---

## Build / test / verify loop

```sh
cd ~/Work/DiskLens
xcodegen generate                                  # ONLY after adding/removing/renaming files
cd Packages/DiskLensCore && swift test             # fast core tests (the TDD inner loop)
cd ~/Work/DiskLens
xcodebuild -scheme DiskLens -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

**Visual verification without Screen Recording permission** — headless snapshot mode
renders the active run's charts to PNGs via `ImageRenderer`:

```sh
APP=$(find ~/Library/Developer/Xcode/DerivedData/DiskLens-*/Build/Products/Debug \
       -maxdepth 1 -name DiskLens.app | head -1)
"$APP/Contents/MacOS/DiskLens" --snapshot /tmp/dlshots && open /tmp/dlshots
```

- It reads the most-recent run from the real store, so you need at least one scan
  saved first (run the app once, or the helper with `--save-run`).
- **The list/table view cannot be snapshotted** — `ImageRenderer` can't capture
  AppKit-backed `Table`; it writes a "prohibited" glyph PNG. That's a tool limit,
  not a bug; the Table renders fine in the live window. Same for the changes
  inspector. Verify those two in the running app.
- The compare snapshot only renders if the store has two runs with the **same
  scanned root**.

---

## Scanner performance (done)

The scanner was rewritten for speed; `~/Work` (1.19M files) went **33.7s → 12.8s** (~2.6×),
accounting unchanged.

- **Bulk metadata:** `getattrlistbulk(2)` reads name + size-on-disk + inode + link-count + mtime
  for a batch of entries per syscall (vs one `lstat` per file). Packed-buffer decode in
  `SubWalk.decode` assumes `FSOPT_PACK_INVAL_ATTRS` (fixed field layout, ascending-bit order). An
  `lstat`/`opendir` fallback (`listViaLstat`) covers filesystems without bulk support; force it
  with `DISKLENS_NO_BULK=1` (also how the `bulkMatchesLstat` test exercises it).
- **Parallel:** the root's child subtrees walk concurrently via `DispatchQueue.concurrentPerform`
  (keeps `scan` synchronous — no async churn in helper/coordinator/tests). Each subtree is a fresh
  `SubWalk` with local stats; they share one `SharedScanState` whose **lock-guarded inode set**
  keeps hard-link dedupe exact across subtrees (see the `crossSubtreeHardlinkDedupe` test), and a
  lock-guarded throttled progress accumulator.
- **Known limit / next lever:** fan-out is single-level (root's children), so a scan dominated by
  one giant subtree (e.g. `/` → `/Users`) is Amdahl-limited. Adaptive/deeper fan-out (expand a
  frontier of directories until there are ≥ ~cores units, then parallelize that) is the next step
  if whole-disk needs to be faster. Hard-link size *attribution* between two links is now
  nondeterministic (whichever subtree is scanned first counts it) — totals stay exact.
- **Progressive rendering (live preview):** `DiskScanner.scan(…, partial:)` streams each top-level
  subtree to the caller **as it finishes** (from the parallel workers — thread-safe required;
  `progressivePartials` test covers it). `AppModel` builds a synthetic live root from the children
  received so far (`beginLivePreview`/`appendLiveChild`/`presentLiveRoot`) so the chart fills in
  mid-scan instead of freezing on stale data; the top strip + a centered spinner show progress, and
  `finishScan` swaps in the authoritative tree. A `scanGen` fence + `stash`/`endLivePreview` make
  late callbacks no-op and restore the prior view on cancel/fail. *Granularity is top-level only*,
  so the dominant subtree still lands in one chunk near the end (same Amdahl seam as above);
  loose root-level files appear only when the final tree arrives. Admin scans don't stream (the
  helper returns the whole tree at once), so they keep the previous run visible + spinner.

## App icon (done)

A generated sunburst icon lives in `App/Assets.xcassets/AppIcon.appiconset` (all 10 macOS
slots). It's rendered by `scripts/make-icon.swift` (CoreGraphics, on a macOS rounded-rect body,
reusing the `ChartPalette` hues so it matches the live charts) and downscaled by
`scripts/make-icon.sh`. To tweak the look, edit the renderer and rerun `./scripts/make-icon.sh`
(no `xcodegen` needed — the catalog is already in the project). The `.appiconset/Contents.json`
is hand-maintained.

**If the Dock/Finder shows a generic icon** after a build, the bundle is fine — it's the macOS
icon cache. Re-register and bounce the Dock, then fully relaunch the app:
`lsregister -f <DiskLens.app>` (full path:
`…/LaunchServices.framework/Versions/A/Support/lsregister`) then `killall Dock`.

## Invariants — don't regress these (they were bugs once)

- **`TreePruner.prune` must return the *same instance* when a subtree is
  unchanged.** The reuse shortcut now compares child *identities*
  (`zip(kept, children).allSatisfy { $0 === $1 }`), not counts. Reverting to a
  count check silently drops deletions deeper than root's direct children. There's
  a `removeDeepGrandchild` regression test guarding this.
- **The collection bag holds `ObjectIdentifier(node)` tied to the current tree.**
  `present(tree:)` clears the bag on any tree swap (scan / run-switch), because a
  stale node can't be located in the new tree and would silently fail to trash.
  A *prune* deliberately does NOT go through `present()` — it preserves identities
  for untouched branches, so the bag stays valid after a trash op.
- **`recomputeDiff` guards on `self.tree?.root === current.root`** so a slow diff
  for an old current tree can't overwrite the fresh one (would tint everything
  gray). Keep that guard if you refactor the compare flow.
- **`deltaByCurrentNode` is keyed by node identity.** Chart tinting only works when
  the displayed tree is the exact tree that was diffed.
- **Destructive actions go through `FileManager.trashItem` only.** Never introduce
  `removeItem`/`unlink`/`rm` on user paths. The root helper must stay scan-only.
- **`actionable(_:)` is the single gate** for reveal/collect/trash. It refuses the
  root node, aggregated `(small files)`, mount points, and unreadable nodes.

---

## Locked decisions (don't re-litigate without reason)

- **Admin elevation = on-demand** (password prompt per scan), behind the
  `ElevationService` protocol. A persistent `SMAppService` Developer-ID daemon is
  the planned drop-in replacement (no re-prompt + scheduled scans).
- **All 6 chart views**, switchable in-app — not a single picked view.
- **Primary metric = size-on-disk** (`st_blocks * 512`, matches `du`). Logical size
  is secondary.
- **Decimal (SI) byte units by default** (matches Finder); binary is a setting.
- **Non-sandboxed** (required for whole-disk scan + elevation).
- **Auto-rescan on launch only re-runs user-mode runs** — never auto-prompts for
  admin (admin stays explicit/on-demand).

---

## Backlog / follow-ups (roughly prioritized)

**Worth doing next**
1. **Persistent helper (`SMAppService`)** — Developer-ID signed daemon implementing
   `ElevationService`; removes the per-scan password prompt and unlocks scheduled
   background scans. The protocol seam is already in place.
2. **Quick Look** — wire spacebar preview on the hovered/selected node.

**Nice to have / polish**
4. **Compare tint on list & bar** — currently sunburst/pie/treemap/icicle tint in
   compare mode; list and bar don't (no natural per-node color surface).
5. **Bar "+N more" indicator** — bar silently shows only the top 24 children.
7. **Bar axis label** — the "Zero kB" tick reads oddly.

**Edge cases (low value, documented)**
8. **Stale-tree delete** — trashing from a cached run whose on-disk state changed
   since the scan could trash a since-replaced path (recoverable via Trash). A
   pre-trash existence/type re-check would harden it.
9. **DiffEngine file↔dir swap** — a same-named entry changing kind between scans
   isn't surfaced as its own change row (children diff instead).
10. **RunStore orphaned blob** — if a stale blob's `removeItem` fails during prune,
    it's left on disk (harmless, just wasted space).
11. **osascript process** isn't force-terminated if the app quits mid-admin-scan
    (the helper finishes and exits on its own).

**Testing**
12. **No app-target tests** — only `DiskLensCore` is unit-tested. The `AppModel`
    state machine (scan/select/compare/trash flows) is reasoned-about, not tested.
    A test target with a mock `RunStore` + `ElevationService` would cover the
    async races that the code-review pass had to verify by hand.

---

## Code-review hardening (commit 27c966c, 2026-06-14)

An `xhigh` review focused on delete safety + all-views QA. Verdict: **the delete
path is safe** (helper is scan-only, Trash-only deletes, app never runs as root so
system files can't be trashed, osascript escaping sound). Fixes applied:

- **Critical:** `TreePruner` reuse-shortcut bug (see Invariants) — trashing any file
  below root's direct children was a silent no-op that also persisted a stale run.
- Bag cleared on tree replacement; `recomputeDiff` stale-tree guard; dangling
  compare baseline cleared on `deleteRun`; auto-rescan no longer re-prompts for
  admin; `actionable()` refuses mount points + unreadable nodes; icicle compare
  tint; list selection cleared on drill.

Intentionally **not** fixed (out of proportion / by design): bar context menu,
bar truncation indicator, DiffEngine dir rows, orphaned-blob cleanup. See backlog.
