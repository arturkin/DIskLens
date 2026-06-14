import Foundation

/// Aggregate counters collected during a scan.
public struct ScanStats: Sendable, Equatable {
    public var filesScanned: Int = 0
    public var directoriesScanned: Int = 0
    public var permissionDenied: Int = 0
    public var symlinks: Int = 0
    public var hardlinksDeduped: Int = 0
}

public enum ScanError: Error {
    case cannotAccessRoot(String)
}

/// Synchronous, cancellable filesystem scanner shared by the app (in-process,
/// user privileges) and the privileged helper (root).
///
/// Size accounting uses allocated blocks (`st_blocks * 512`, matching `du`):
/// hard links are counted once, symlinks are not followed, and scanning stops
/// at volume boundaries unless `crossMountPoints` is set.
public struct Scanner: Sendable {
    public struct Result: Sendable {
        public let tree: FileTree
        public let stats: ScanStats
    }

    /// How many files between throttled progress callbacks.
    public var progressInterval: Int

    public init(progressInterval: Int = 512) {
        self.progressInterval = progressInterval
    }

    public func scan(
        _ options: ScanOptions,
        cancellation: ScanCancellation? = nil,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) throws -> Result {
        let walk = Walk(
            options: options,
            cancellation: cancellation,
            progress: progress,
            progressInterval: progressInterval
        )
        let rootPath = options.root.standardizedFileURL.path
        let root = try walk.run(rootPath: rootPath)
        return Result(tree: FileTree(root: root, scannedRoot: rootPath), stats: walk.stats)
    }
}

// MARK: - Walk (per-scan mutable state)

private struct InodeKey: Hashable {
    let dev: dev_t
    let ino: ino_t
}

private final class Walk {
    let options: ScanOptions
    let cancellation: ScanCancellation?
    let progress: (@Sendable (ScanProgress) -> Void)?
    let progressInterval: Int
    let excluded: Set<String>

    private let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext",
        "photoslibrary", "fcpbundle", "rtfd", "xcodeproj"
    ]

    var seenInodes = Set<InodeKey>()
    var stats = ScanStats()
    var bytesScanned: Int64 = 0
    private var lastProgressFiles = 0

    init(
        options: ScanOptions,
        cancellation: ScanCancellation?,
        progress: (@Sendable (ScanProgress) -> Void)?,
        progressInterval: Int
    ) {
        self.options = options
        self.cancellation = cancellation
        self.progress = progress
        self.progressInterval = max(1, progressInterval)
        self.excluded = Set(options.excludePaths.map { $0.standardizedFileURL.path })
    }

    func run(rootPath: String) throws -> FileNode {
        var st = stat()
        guard lstat(rootPath, &st) == 0 else { throw ScanError.cannotAccessRoot(rootPath) }

        let name = Self.rootName(for: rootPath)
        let node: FileNode
        if Self.modeType(st) == Self.typeDir {
            node = try buildDirectory(path: rootPath, name: name, st: st, parentDev: st.st_dev)
        } else {
            // Scanning a single file: a one-node tree.
            let size = Int64(st.st_blocks) * 512
            stats.filesScanned += 1
            bytesScanned += size
            node = FileNode(
                name: name, isDirectory: false, sizeOnDisk: size,
                logicalSize: Int64(st.st_size), modified: Self.mtime(st), fileCount: 1
            )
        }
        // Always emit a final, exact tally.
        progress?(ScanProgress(
            filesScanned: stats.filesScanned, bytesScanned: bytesScanned, currentPath: rootPath))
        return node
    }

    private func buildDirectory(path: String, name: String, st: stat, parentDev: dev_t) throws -> FileNode {
        try checkCancellation()

        var dirFlags: NodeFlags = []
        if st.st_dev != parentDev { dirFlags.insert(.mountPoint) }

        guard let dirp = opendir(path) else {
            stats.permissionDenied += 1
            return FileNode(
                name: name, isDirectory: true,
                sizeOnDisk: Int64(st.st_blocks) * 512, logicalSize: Int64(st.st_size),
                modified: Self.mtime(st), fileCount: 0,
                flags: dirFlags.union(.permissionDenied), children: []
            )
        }
        defer { closedir(dirp) }

        var children: [FileNode] = []
        var totalSize = Int64(st.st_blocks) * 512
        var totalLogical = Int64(st.st_size)
        var totalFiles: Int32 = 0

        var smallSize: Int64 = 0
        var smallLogical: Int64 = 0
        var smallCount: Int32 = 0

        var processed = 0
        while let entp = readdir(dirp) {
            let cname = Self.entryName(entp)
            if cname == "." || cname == ".." { continue }
            let childPath = path.hasSuffix("/") ? path + cname : path + "/" + cname
            if excluded.contains(childPath) { continue }

            var cst = stat()
            guard lstat(childPath, &cst) == 0 else { continue }   // raced/vanished
            let mode = Self.modeType(cst)

            if mode == Self.typeDir {
                if cst.st_dev != st.st_dev && !options.crossMountPoints {
                    // Mount point: record it but do not descend onto another volume.
                    let node = FileNode(
                        name: cname, isDirectory: true,
                        sizeOnDisk: Int64(cst.st_blocks) * 512, logicalSize: Int64(cst.st_size),
                        modified: Self.mtime(cst), fileCount: 0, flags: [.mountPoint], children: []
                    )
                    children.append(node)
                    totalSize += node.sizeOnDisk
                    totalLogical += node.logicalSize
                } else {
                    let sub = try buildDirectory(path: childPath, name: cname, st: cst, parentDev: st.st_dev)
                    let node: FileNode
                    if options.treatPackagesAsFiles && isPackage(cname) {
                        node = FileNode(
                            name: cname, isDirectory: true,
                            sizeOnDisk: sub.sizeOnDisk, logicalSize: sub.logicalSize,
                            modified: sub.modified, fileCount: sub.fileCount,
                            flags: sub.flags.union(.package), children: []
                        )
                    } else {
                        node = sub
                    }
                    children.append(node)
                    totalSize += node.sizeOnDisk
                    totalLogical += node.logicalSize
                    totalFiles += node.fileCount
                }
            } else {
                // File, symlink, or special node → leaf.
                let isLink = mode == Self.typeLink
                var size = Int64(cst.st_blocks) * 512
                let logical = Int64(cst.st_size)
                let leafFlags: NodeFlags = isLink ? [.symlink] : []

                if !isLink, mode == Self.typeReg, cst.st_nlink > 1 {
                    let key = InodeKey(dev: cst.st_dev, ino: cst.st_ino)
                    if seenInodes.contains(key) {
                        size = 0   // already counted via the first link
                        stats.hardlinksDeduped += 1
                    } else {
                        seenInodes.insert(key)
                    }
                }

                if isLink { stats.symlinks += 1 }
                stats.filesScanned += 1
                bytesScanned += size

                if options.minRetainedSize > 0, !isLink, size < options.minRetainedSize {
                    smallSize += size
                    smallLogical += logical
                    smallCount += 1
                } else {
                    children.append(FileNode(
                        name: cname, isDirectory: false, sizeOnDisk: size, logicalSize: logical,
                        modified: Self.mtime(cst), fileCount: 1, flags: leafFlags, children: []
                    ))
                    totalSize += size
                    totalLogical += logical
                    totalFiles += 1
                }
                maybeReportProgress(childPath)
            }

            processed += 1
            if processed % 512 == 0 { try checkCancellation() }
        }

        if smallCount > 0 {
            children.append(FileNode(
                name: "(small files)", isDirectory: false,
                sizeOnDisk: smallSize, logicalSize: smallLogical, modified: nil,
                fileCount: smallCount, flags: [.aggregatedSmallFiles], children: []
            ))
            totalSize += smallSize
            totalLogical += smallLogical
            totalFiles += smallCount
        }

        stats.directoriesScanned += 1
        children.sort { $0.sizeOnDisk > $1.sizeOnDisk }

        return FileNode(
            name: name, isDirectory: true,
            sizeOnDisk: totalSize, logicalSize: totalLogical, modified: Self.mtime(st),
            fileCount: totalFiles, flags: dirFlags, children: children
        )
    }

    // MARK: Helpers

    private func checkCancellation() throws {
        if cancellation?.isCancelled == true { throw CancellationError() }
    }

    private func maybeReportProgress(_ path: String) {
        guard let progress else { return }
        if stats.filesScanned - lastProgressFiles >= progressInterval {
            lastProgressFiles = stats.filesScanned
            progress(ScanProgress(
                filesScanned: stats.filesScanned, bytesScanned: bytesScanned, currentPath: path))
        }
    }

    private func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return packageExtensions.contains(ext)
    }

    private static let typeMask = mode_t(S_IFMT)
    static let typeDir = mode_t(S_IFDIR)
    static let typeLink = mode_t(S_IFLNK)
    static let typeReg = mode_t(S_IFREG)

    private static func modeType(_ st: stat) -> mode_t {
        st.st_mode & typeMask
    }

    private static func mtime(_ st: stat) -> Date? {
        let ts = st.st_mtimespec
        if ts.tv_sec == 0 && ts.tv_nsec == 0 { return nil }
        return Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000)
    }

    private static func rootName(for path: String) -> String {
        if path == "/" { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let comp = (trimmed as NSString).lastPathComponent
        return comp.isEmpty ? trimmed : comp
    }

    private static func entryName(_ entp: UnsafeMutablePointer<dirent>) -> String {
        var ent = entp.pointee
        return withUnsafeBytes(of: &ent.d_name) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}
