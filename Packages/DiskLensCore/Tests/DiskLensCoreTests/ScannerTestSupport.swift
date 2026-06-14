import Foundation
@testable import DiskLensCore

/// Builds and tears down a temporary directory tree for scanner tests.
final class TempTree {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskLensScan-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func dir(_ relativePath: String) -> URL {
        let url = root.appending(path: relativePath)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a file of `bytes` real (non-sparse) zero bytes, creating parents.
    @discardableResult
    func file(_ relativePath: String, bytes: Int) -> URL {
        let url = root.appending(path: relativePath)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(count: bytes).write(to: url)
        return url
    }

    func symlink(_ relativePath: String, to target: URL) {
        let url = root.appending(path: relativePath)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    func hardlink(_ relativePath: String, to target: URL) {
        let url = root.appending(path: relativePath)
        try! FileManager.default.linkItem(at: target, to: url)
    }

    /// `du -s` in 512-byte blocks → bytes. Matches `st_blocks * 512` accounting.
    func duBytes(_ url: URL? = nil) -> Int64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-s", (url ?? root).path]
        p.environment = ["BLOCKSIZE": "512"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try! p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let blocks = Int64(text.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "0") ?? 0
        return blocks * 512
    }
}

extension FileNode {
    func child(_ name: String) -> FileNode? {
        children.first { $0.name == name }
    }
}

/// Captures progress callbacks from a synchronous scan.
final class ProgressCollector: @unchecked Sendable {
    private(set) var events: [ScanProgress] = []
    func record(_ p: ScanProgress) { events.append(p) }
    var last: ScanProgress? { events.last }
}

/// Thread-safe collector for the scanner's `partial` callback, which fires from
/// the parallel subtree workers.
final class NodeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FileNode] = []
    func add(_ node: FileNode) { lock.withLock { storage.append(node) } }
    var nodes: [FileNode] { lock.withLock { storage } }
}
