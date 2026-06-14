# DiskLens

A native macOS disk visualizer & cleaner (a personal DaisyDisk replacement).

- Scan a folder, a volume, or the whole disk — with an optional **admin (root)** scan via an
  on-demand authorization prompt.
- Explore where space goes with **switchable visualizations**: sunburst, treemap, pie/drill-down,
  sortable list/table, icicle, and bar.
- Every scan is **cached as a run**; the last run loads instantly on launch and history is
  browsable.
- **Compare** any run against a previous one to see what was added / grew / removed.
- Clean up with Reveal in Finder, Quick Look, Move to Trash, and a batch **collection bag**.

## Layout

```
Packages/DiskLensCore/   Pure logic (no UI): model, scanner, diff, codec, store. `swift test`.
App/                     SwiftUI app target "DiskLens".
Helper/                  "disklens-helper" CLI, embedded in the app, run as root for admin scans.
project.yml              XcodeGen spec — single source of truth for the Xcode project.
```

## Build & test

```sh
# 1. Generate the Xcode project from project.yml (the .xcodeproj is gitignored)
xcodegen generate

# 2. Run the core unit tests (fast, no app build)
cd Packages/DiskLensCore && swift test

# 3. Build the app + helper
xcodebuild -scheme DiskLens -destination 'platform=macOS' build
# (add CODE_SIGNING_ALLOWED=NO for an unsigned local build)

# 4. Or just open it
open DiskLens.xcodeproj
```

Requires Xcode 16+ (built with 26.2), macOS 14+ deployment target, and
[`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

The app is **non-sandboxed** (required to scan the whole disk). For fullest non-admin coverage,
grant it **Full Disk Access** in System Settings → Privacy & Security.
