import Foundation
@testable import DiskLensCore

enum Fixtures {
    /// A small, deterministic tree:
    /// root(/tmp/x) [dir]
    ///   ├─ a.txt [file 1000/1024]
    ///   └─ sub [dir]
    ///        ├─ b.bin [file 4096/4096]
    ///        └─ link  [symlink 0/0]
    static func sampleTree(root: String = "/tmp/x") -> FileTree {
        let aTxt = FileNode(
            name: "a.txt", isDirectory: false,
            sizeOnDisk: 1024, logicalSize: 1000,
            modified: Date(timeIntervalSince1970: 1_700_000_000), fileCount: 1
        )
        let bBin = FileNode(
            name: "b.bin", isDirectory: false,
            sizeOnDisk: 4096, logicalSize: 4096,
            modified: Date(timeIntervalSince1970: 1_700_000_100), fileCount: 1
        )
        let link = FileNode(
            name: "link", isDirectory: false,
            sizeOnDisk: 0, logicalSize: 0,
            modified: nil, fileCount: 1, flags: [.symlink]
        )
        let sub = FileNode(
            name: "sub", isDirectory: true,
            sizeOnDisk: 4096, logicalSize: 4096,
            modified: nil, fileCount: 2, children: [bBin, link]
        )
        let rootNode = FileNode(
            name: "x", isDirectory: true,
            sizeOnDisk: 5120, logicalSize: 5096,
            modified: nil, fileCount: 3, children: [aTxt, sub]
        )
        return FileTree(root: rootNode, scannedRoot: root)
    }

    static func metadata(date: Date, total: Int64, files: Int) -> RunMetadata {
        RunMetadata(
            date: date, scannedRoot: "/tmp/x", mode: .user, volumeName: "Macintosh HD",
            totalSize: total, fileCount: files, durationMs: 42, appVersion: "test"
        )
    }
}

/// Recursively compares two trees for value equality (FileNode is a reference type).
func assertTreesEqual(_ a: FileNode, _ b: FileNode, path: String = "") -> Bool {
    guard a.name == b.name,
          a.isDirectory == b.isDirectory,
          a.sizeOnDisk == b.sizeOnDisk,
          a.logicalSize == b.logicalSize,
          a.modified == b.modified,
          a.fileCount == b.fileCount,
          a.flags == b.flags,
          a.children.count == b.children.count
    else { return false }
    for (ca, cb) in zip(a.children, b.children) {
        if !assertTreesEqual(ca, cb, path: path + "/" + a.name) { return false }
    }
    return true
}
