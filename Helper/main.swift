import Foundation
import DiskLensCore

// disklens-helper — the scanning CLI.
//
// Used two ways:
//   • Embedded in the app and launched as root for an admin scan (M7), writing a
//     TreeCodec blob to --out and progress JSON to --progress.
//   • Directly from the command line for headless/user scans, optionally saving
//     a run into the default RunStore via --save-run.
//
// Usage:
//   disklens-helper --root <path> [--out <blob>] [--progress <file>]
//                   [--save-run] [--min-size <bytes>] [--cross-mounts]

struct ProgressRecord: Encodable {
    let files: Int
    let bytes: Int64
    let path: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("disklens-helper: \(message)\n".utf8))
    exit(2)
}

/// Nonisolated so the `@Sendable` progress closure can capture its locals.
func performScan(
    rootPath: String,
    outPath: String?,
    progressPath: String?,
    saveRun: Bool,
    minSize: Int64,
    crossMounts: Bool
) {
    let options = ScanOptions(
        root: URL(filePath: rootPath),
        crossMountPoints: crossMounts,
        minRetainedSize: minSize
    )

    let started = Date()
    let result: DiskScanner.Result
    do {
        result = try DiskScanner().scan(options) { progress in
            guard let progressPath else { return }
            let record = ProgressRecord(
                files: progress.filesScanned, bytes: progress.bytesScanned, path: progress.currentPath)
            if let data = try? JSONEncoder().encode(record) {
                try? data.write(to: URL(filePath: progressPath), options: .atomic)
            }
        }
    } catch {
        fail("scan failed: \(error)")
    }

    let elapsed = Date().timeIntervalSince(started)
    let tree = result.tree

    if let outPath {
        do {
            try TreeCodec.encode(tree).write(to: URL(filePath: outPath), options: .atomic)
        } catch {
            fail("could not write blob: \(error)")
        }
    }

    if saveRun {
        let meta = RunMetadata(
            date: Date(),
            scannedRoot: tree.scannedRoot,
            mode: .user,
            volumeName: nil,
            totalSize: tree.root.sizeOnDisk,
            fileCount: Int(tree.root.fileCount),
            durationMs: Int(elapsed * 1000),
            appVersion: "cli"
        )
        do {
            try RunStore().save(tree: tree, metadata: meta)
        } catch {
            fail("could not save run: \(error)")
        }
    }

    let summary = """
    scanned \(tree.scannedRoot)
      size on disk: \(tree.root.sizeOnDisk) bytes
      files: \(result.stats.filesScanned)  dirs: \(result.stats.directoriesScanned)
      symlinks: \(result.stats.symlinks)  hardlinks deduped: \(result.stats.hardlinksDeduped)  unreadable: \(result.stats.permissionDenied)
      elapsed: \(String(format: "%.2f", elapsed))s
    """
    FileHandle.standardError.write(Data((summary + "\n").utf8))
}

// MARK: - Parse arguments (top level — main actor)

var rootPath: String?
var outPath: String?
var progressPath: String?
var saveRun = false
var minSize: Int64 = 0
var crossMounts = false

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--root":         rootPath = argIterator.next()
    case "--out":          outPath = argIterator.next()
    case "--progress":     progressPath = argIterator.next()
    case "--save-run":     saveRun = true
    case "--cross-mounts": crossMounts = true
    case "--min-size":     minSize = argIterator.next().flatMap { Int64($0) } ?? 0
    default:               fail("unknown argument \(arg)")
    }
}

guard let resolvedRoot = rootPath else { fail("--root is required") }

performScan(
    rootPath: resolvedRoot,
    outPath: outPath,
    progressPath: progressPath,
    saveRun: saveRun,
    minSize: minSize,
    crossMounts: crossMounts
)
