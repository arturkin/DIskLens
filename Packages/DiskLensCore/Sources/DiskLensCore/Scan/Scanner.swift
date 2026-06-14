import Foundation
import Dispatch
import os

/// Aggregate counters collected during a scan.
public struct ScanStats: Sendable, Equatable {
    public var filesScanned: Int = 0
    public var directoriesScanned: Int = 0
    public var permissionDenied: Int = 0
    public var symlinks: Int = 0
    public var hardlinksDeduped: Int = 0

    static func + (a: ScanStats, b: ScanStats) -> ScanStats {
        var r = a
        r.filesScanned += b.filesScanned
        r.directoriesScanned += b.directoriesScanned
        r.permissionDenied += b.permissionDenied
        r.symlinks += b.symlinks
        r.hardlinksDeduped += b.hardlinksDeduped
        return r
    }
}

public enum ScanError: Error {
    case cannotAccessRoot(String)
}

/// Synchronous, cancellable filesystem scanner shared by the app (in-process,
/// user privileges) and the privileged helper (root).
///
/// Size accounting uses allocated blocks (matching `du`): hard links are counted
/// once, symlinks are not followed, and scanning stops at volume boundaries
/// unless `crossMountPoints` is set.
///
/// **Speed comes from two things.** Directory entries are read with
/// `getattrlistbulk(2)` — one syscall returns each entry's name, type, allocated
/// size, inode, link count and mtime for a whole batch, so files are *not*
/// individually `lstat`-ed. And the root's child subtrees are walked **in
/// parallel** across cores (`DispatchQueue.concurrentPerform`), sharing one
/// lock-guarded inode set so hard-link dedupe stays exact across subtrees.
public struct DiskScanner: Sendable {
    public struct Result: Sendable {
        public let tree: FileTree
        public let stats: ScanStats
    }

    /// How many files between throttled progress callbacks.
    public var progressInterval: Int

    /// Force the per-entry `lstat` listing path (skip `getattrlistbulk`). Used on
    /// filesystems without bulk support and to A/B or test the fallback. Defaults
    /// to the `DISKLENS_NO_BULK` environment variable being set.
    var forceLstatListing: Bool

    public init(progressInterval: Int = 512) {
        self.progressInterval = progressInterval
        self.forceLstatListing = ProcessInfo.processInfo.environment["DISKLENS_NO_BULK"] != nil
    }

    public func scan(
        _ options: ScanOptions,
        cancellation: ScanCancellation? = nil,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) throws -> Result {
        let rootPath = options.root.standardizedFileURL.path
        var st = stat()
        guard lstat(rootPath, &st) == 0 else { throw ScanError.cannotAccessRoot(rootPath) }
        let name = SubWalk.rootName(for: rootPath)

        // A single file: a one-node tree, no directory walk.
        if SubWalk.modeType(st) != SubWalk.typeDir {
            let size = Int64(st.st_blocks) * 512
            var s = ScanStats(); s.filesScanned = 1
            progress?(ScanProgress(filesScanned: 1, bytesScanned: size, currentPath: rootPath))
            let node = FileNode(
                name: name, isDirectory: false, sizeOnDisk: size,
                logicalSize: Int64(st.st_size), modified: SubWalk.mtime(st), fileCount: 1)
            return Result(tree: FileTree(root: node, scannedRoot: rootPath), stats: s)
        }

        let shared = SharedScanState(
            options: options, cancellation: cancellation,
            progress: progress, progressInterval: max(1, progressInterval),
            forceLstat: forceLstatListing)

        let rootWalk = SubWalk(shared: shared)
        switch try rootWalk.openAndList(path: rootPath, name: name, parentDev: st.st_dev) {
        case .terminal(let node):
            return Result(tree: FileTree(root: node, scannedRoot: rootPath), stats: rootWalk.stats)

        case .open(let shell):
            let subdirs = shell.subdirs
            var children: [FileNode] = []
            var merged = rootWalk.stats

            if !subdirs.isEmpty {
                let n = subdirs.count
                let nodesP = UnsafeMutablePointer<FileNode?>.allocate(capacity: n)
                nodesP.initialize(repeating: nil, count: n)
                let statsP = UnsafeMutablePointer<ScanStats>.allocate(capacity: n)
                statsP.initialize(repeating: ScanStats(), count: n)
                defer {
                    nodesP.deinitialize(count: n); nodesP.deallocate()
                    statsP.deinitialize(count: n); statsP.deallocate()
                }
                // Distinct indices → race-free writes; the Sink wrapper carries the
                // pointers across the concurrent closure boundary.
                let nodes = Sink(p: nodesP), stats = Sink(p: statsP)
                let dev = shell.dev
                DispatchQueue.concurrentPerform(iterations: n) { i in
                    let w = SubWalk(shared: shared)
                    let sd = subdirs[i]
                    if let node = try? w.buildSubtree(path: sd.path, name: sd.name, parentDev: dev) {
                        nodes.p[i] = w.collapseIfPackage(node, name: sd.name)
                    }
                    stats.p[i] = w.stats
                }
                for i in 0..<n {
                    if let node = nodesP[i] { children.append(node) }
                    merged = merged + statsP[i]
                }
            }

            if cancellation?.isCancelled == true { throw CancellationError() }
            let root = rootWalk.assemble(shell, extraChildren: children)
            shared.finalProgress(path: rootPath)
            return Result(tree: FileTree(root: root, scannedRoot: rootPath), stats: merged)
        }
    }
}

/// Carries unsafe pointers into `concurrentPerform`'s closure. Safe because each
/// iteration writes only its own index.
private struct Sink<T>: @unchecked Sendable { let p: UnsafeMutablePointer<T> }

// MARK: - Shared state (one per scan, touched by every parallel subtree)

private struct InodeKey: Hashable {
    let dev: dev_t
    let ino: ino_t
}

/// State shared across the parallel subtree walks: the options, the global
/// hard-link dedupe set, and the throttled progress accumulator. All mutable
/// access is lock-guarded, so it is safe to hand to concurrent walkers.
private final class SharedScanState: @unchecked Sendable {
    let options: ScanOptions
    let excluded: Set<String>
    let cancellation: ScanCancellation?
    let progress: (@Sendable (ScanProgress) -> Void)?
    let progressInterval: Int
    let forceLstat: Bool

    private let seen = OSAllocatedUnfairLock(initialState: Set<InodeKey>())
    private struct Prog { var files = 0; var bytes: Int64 = 0; var lastReported = 0 }
    private let prog = OSAllocatedUnfairLock(initialState: Prog())

    init(
        options: ScanOptions, cancellation: ScanCancellation?,
        progress: (@Sendable (ScanProgress) -> Void)?, progressInterval: Int, forceLstat: Bool
    ) {
        self.options = options
        self.excluded = Set(options.excludePaths.map { $0.standardizedFileURL.path })
        self.cancellation = cancellation
        self.progress = progress
        self.progressInterval = progressInterval
        self.forceLstat = forceLstat
    }

    /// True if this `(dev, ino)` is newly seen and should be counted; false if it
    /// is a hard link to an already-counted inode.
    func firstSighting(_ key: InodeKey) -> Bool {
        seen.withLock { $0.insert(key).inserted }
    }

    /// Folds a directory's leaf tally into the cumulative total, firing the
    /// throttled callback when enough files have accrued since the last report.
    func reportProgress(files: Int, bytes: Int64, path: String) {
        guard let progress, files > 0 || bytes > 0 else { return }
        let snapshot: ScanProgress? = prog.withLock { st in
            st.files += files
            st.bytes += bytes
            if st.files - st.lastReported >= progressInterval {
                st.lastReported = st.files
                return ScanProgress(filesScanned: st.files, bytesScanned: st.bytes, currentPath: path)
            }
            return nil
        }
        if let snapshot { progress(snapshot) }
    }

    func finalProgress(path: String) {
        guard let progress else { return }
        let snapshot = prog.withLock {
            ScanProgress(filesScanned: $0.files, bytesScanned: $0.bytes, currentPath: path)
        }
        progress(snapshot)
    }
}

// MARK: - Per-subtree walker

/// One directory's children and running totals while it is scanned.
private final class DirAcc {
    var children: [FileNode] = []
    var totalSize: Int64
    var totalLogical: Int64
    var totalFiles: Int32 = 0
    var smallSize: Int64 = 0
    var smallLogical: Int64 = 0
    var smallCount: Int32 = 0

    init(ownSize: Int64, ownLogical: Int64) {
        totalSize = ownSize
        totalLogical = ownLogical
    }
}

/// A directory opened for scanning: its own metadata, accumulated leaf children,
/// and the subdirectories still to walk.
private final class DirShell {
    let name: String
    let dev: dev_t
    let ownMtime: Date?
    let flags: NodeFlags
    let acc: DirAcc
    var subdirs: [(name: String, path: String)]

    init(name: String, dev: dev_t, ownMtime: Date?, flags: NodeFlags,
         acc: DirAcc, subdirs: [(name: String, path: String)]) {
        self.name = name; self.dev = dev; self.ownMtime = ownMtime
        self.flags = flags; self.acc = acc; self.subdirs = subdirs
    }
}

private enum DirListing {
    case terminal(FileNode)   // mount stub or unreadable dir — nothing to walk
    case open(DirShell)
}

/// One raw directory entry, decoded from either listing path.
private struct RawEntry {
    let name: String
    let objType: Int32
    let sizeOnDisk: Int64
    let logical: Int64
    let fileid: UInt64
    let linkCount: UInt32
    let mtime: Date?
}

/// Walks one subtree synchronously. Each parallel root-child gets its own
/// instance (so `stats` need no locking); all instances share one
/// `SharedScanState` for dedupe and progress.
private final class SubWalk {
    let shared: SharedScanState
    var stats = ScanStats()
    var bytesScanned: Int64 = 0   // for progress only

    private let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext",
        "photoslibrary", "fcpbundle", "rtfd", "xcodeproj"
    ]

    init(shared: SharedScanState) { self.shared = shared }

    private var options: ScanOptions { shared.options }

    /// Recursively builds a full subtree rooted at `path`.
    func buildSubtree(path: String, name: String, parentDev: dev_t) throws -> FileNode {
        switch try openAndList(path: path, name: name, parentDev: parentDev) {
        case .terminal(let node):
            return node
        case .open(let shell):
            var children: [FileNode] = []
            children.reserveCapacity(shell.subdirs.count)
            for sd in shell.subdirs {
                let child = try buildSubtree(path: sd.path, name: sd.name, parentDev: shell.dev)
                children.append(collapseIfPackage(child, name: sd.name))
            }
            return assemble(shell, extraChildren: children)
        }
    }

    /// Stats a directory, lists its entries (accounting leaves, collecting
    /// subdirectories), and returns its shell — or a terminal node if it is a
    /// mount point we won't cross or a directory we can't read.
    func openAndList(path: String, name: String, parentDev: dev_t) throws -> DirListing {
        try checkCancellation()

        var st = stat()
        guard lstat(path, &st) == 0 else {
            stats.permissionDenied += 1
            return .terminal(FileNode(
                name: name, isDirectory: true, sizeOnDisk: 0, logicalSize: 0,
                modified: nil, fileCount: 0, flags: .permissionDenied, children: []))
        }

        let myDev = st.st_dev
        let ownSize = Int64(st.st_blocks) * 512
        let ownLogical = Int64(st.st_size)
        let ownMtime = Self.mtime(st)

        var dirFlags: NodeFlags = []
        if myDev != parentDev {
            dirFlags.insert(.mountPoint)
            if !options.crossMountPoints {
                return .terminal(FileNode(
                    name: name, isDirectory: true, sizeOnDisk: ownSize, logicalSize: ownLogical,
                    modified: ownMtime, fileCount: 0, flags: [.mountPoint], children: []))
            }
        }

        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            stats.permissionDenied += 1
            return .terminal(FileNode(
                name: name, isDirectory: true, sizeOnDisk: ownSize, logicalSize: ownLogical,
                modified: ownMtime, fileCount: 0,
                flags: dirFlags.union(.permissionDenied), children: []))
        }
        defer { close(fd) }

        let acc = DirAcc(ownSize: ownSize, ownLogical: ownLogical)
        var subdirs: [(name: String, path: String)] = []
        let f0 = stats.filesScanned, b0 = bytesScanned
        let hasExcludes = !shared.excluded.isEmpty

        try enumerate(fd: fd, dirPath: path) { entry in
            if entry.name == "." || entry.name == ".." { return }
            if entry.objType == Self.objDir {
                let childPath = Self.join(path, entry.name)
                if hasExcludes && shared.excluded.contains(childPath) { return }
                subdirs.append((entry.name, childPath))
            } else {
                if hasExcludes && shared.excluded.contains(Self.join(path, entry.name)) { return }
                accountLeaf(entry, dev: myDev, into: acc)
            }
        }

        stats.directoriesScanned += 1
        shared.reportProgress(files: stats.filesScanned - f0, bytes: bytesScanned - b0, path: path)
        return .open(DirShell(
            name: name, dev: myDev, ownMtime: ownMtime, flags: dirFlags, acc: acc, subdirs: subdirs))
    }

    /// Finalizes a directory node: appends the walked subdirectory children, folds
    /// in the aggregated small-files leaf, sorts, and freezes to a `FileNode`.
    func assemble(_ shell: DirShell, extraChildren: [FileNode]) -> FileNode {
        let acc = shell.acc
        for child in extraChildren {
            acc.children.append(child)
            acc.totalSize += child.sizeOnDisk
            acc.totalLogical += child.logicalSize
            acc.totalFiles += child.fileCount
        }
        if acc.smallCount > 0 {
            acc.children.append(FileNode(
                name: "(small files)", isDirectory: false,
                sizeOnDisk: acc.smallSize, logicalSize: acc.smallLogical, modified: nil,
                fileCount: acc.smallCount, flags: [.aggregatedSmallFiles], children: []))
            acc.totalSize += acc.smallSize
            acc.totalLogical += acc.smallLogical
            acc.totalFiles += acc.smallCount
        }
        acc.children.sort { $0.sizeOnDisk > $1.sizeOnDisk }
        return FileNode(
            name: shell.name, isDirectory: true,
            sizeOnDisk: acc.totalSize, logicalSize: acc.totalLogical, modified: shell.ownMtime,
            fileCount: acc.totalFiles, flags: shell.flags, children: acc.children)
    }

    func collapseIfPackage(_ node: FileNode, name: String) -> FileNode {
        guard options.treatPackagesAsFiles, isPackage(name) else { return node }
        return FileNode(
            name: name, isDirectory: true, sizeOnDisk: node.sizeOnDisk,
            logicalSize: node.logicalSize, modified: node.modified, fileCount: node.fileCount,
            flags: node.flags.union(.package), children: [])
    }

    /// Folds one leaf entry into `acc` (hard-link dedupe + small-file aggregation).
    private func accountLeaf(_ e: RawEntry, dev: dev_t, into acc: DirAcc) {
        let isLink = e.objType == Self.objLink
        var size = e.sizeOnDisk

        if !isLink, e.objType == Self.objReg, e.linkCount > 1 {
            let key = InodeKey(dev: dev, ino: ino_t(e.fileid))
            if !shared.firstSighting(key) {
                size = 0   // already counted via the first link
                stats.hardlinksDeduped += 1
            }
        }

        if isLink { stats.symlinks += 1 }
        stats.filesScanned += 1
        bytesScanned += size

        if options.minRetainedSize > 0, !isLink, size < options.minRetainedSize {
            acc.smallSize += size
            acc.smallLogical += e.logical
            acc.smallCount += 1
        } else {
            acc.children.append(FileNode(
                name: e.name, isDirectory: false, sizeOnDisk: size, logicalSize: e.logical,
                modified: e.mtime, fileCount: 1, flags: isLink ? [.symlink] : [], children: []))
            acc.totalSize += size
            acc.totalLogical += e.logical
            acc.totalFiles += 1
        }
    }

    // MARK: Listing

    private func enumerate(fd: Int32, dirPath: String, _ handler: (RawEntry) throws -> Void) throws {
        if shared.forceLstat {
            try listViaLstat(dirPath: dirPath, handler)
        } else if try !listViaBulk(fd: fd, handler) {
            try listViaLstat(dirPath: dirPath, handler)
        }
    }

    /// Reads `fd`'s entries in batches via `getattrlistbulk`. Returns `false`
    /// (consuming nothing) when the filesystem lacks bulk support, so the caller
    /// falls back to `lstat`.
    private func listViaBulk(fd: Int32, _ handler: (RawEntry) throws -> Void) throws -> Bool {
        var al = attrlist()
        al.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        al.commonattr = Self.cmnReturned | Self.cmnName | Self.cmnObjType
            | Self.cmnModtime | Self.cmnFileID | Self.cmnError
        al.fileattr = Self.fileLinkCount | Self.fileAllocSize | Self.fileDataLength

        let bufSize = 1 << 18   // 256 KB
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }

        var first = true
        var processed = 0

        while true {
            let count = withUnsafeMutablePointer(to: &al) { alp in
                getattrlistbulk(fd, UnsafeMutableRawPointer(alp), buf, bufSize, Self.packInvalAttrs)
            }
            if count == -1 {
                if first && (errno == ENOTSUP || errno == EINVAL) { return false }
                break   // mid-listing error: stop with what we have
            }
            if count == 0 { break }
            first = false

            var entry = UnsafeRawPointer(buf)
            for _ in 0..<Int(count) {
                let length = try decode(entry, handler)
                entry = entry.advanced(by: length)
                processed += 1
                if processed % 1024 == 0 { try checkCancellation() }
            }
        }
        return true
    }

    /// Decodes one packed `getattrlistbulk` record and hands it to `handler`.
    /// Returns the record length so the caller can advance to the next entry.
    ///
    /// Layout (with `FSOPT_PACK_INVAL_ATTRS`, so every requested attribute is
    /// always present): `[u32 length][attribute_set_t returned (20B)]` then the
    /// requested attributes in ascending-bit order — name ref, objtype, modtime,
    /// fileid, error, then file linkcount, allocsize, datalength.
    private func decode(_ entry: UnsafeRawPointer, _ handler: (RawEntry) throws -> Void) throws -> Int {
        var cursor = 0
        func u32() -> UInt32 { defer { cursor += 4 }; return entry.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) }
        func i32() -> Int32  { defer { cursor += 4 }; return entry.loadUnaligned(fromByteOffset: cursor, as: Int32.self) }
        func u64() -> UInt64 { defer { cursor += 8 }; return entry.loadUnaligned(fromByteOffset: cursor, as: UInt64.self) }
        func i64() -> Int64  { defer { cursor += 8 }; return entry.loadUnaligned(fromByteOffset: cursor, as: Int64.self) }
        func word() -> Int   { defer { cursor += MemoryLayout<Int>.size }; return entry.loadUnaligned(fromByteOffset: cursor, as: Int.self) }

        let length = Int(u32())
        cursor += 20                       // skip ATTR_CMN_RETURNED_ATTRS (attribute_set_t)

        let nameFieldPos = cursor
        let nameOffset = Int(i32())        // attrreference_t.attr_dataoffset
        _ = u32()                          // attrreference_t.attr_length (unused)

        let objType = i32()                // ATTR_CMN_OBJTYPE
        let secs = word()                  // ATTR_CMN_MODTIME.tv_sec
        let nsecs = word()                 // ATTR_CMN_MODTIME.tv_nsec
        let fileid = u64()                 // ATTR_CMN_FILEID
        _ = u32()                          // ATTR_CMN_ERROR
        let linkCount = u32()              // ATTR_FILE_LINKCOUNT
        let allocSize = i64()              // ATTR_FILE_ALLOCSIZE (size on disk)
        let dataLength = i64()             // ATTR_FILE_DATALENGTH (logical size)

        let name = String(cString: (entry + nameFieldPos + nameOffset).assumingMemoryBound(to: CChar.self))
        let mtime: Date? = (secs == 0 && nsecs == 0)
            ? nil : Date(timeIntervalSince1970: Double(secs) + Double(nsecs) / 1_000_000_000)

        try handler(RawEntry(
            name: name, objType: objType, sizeOnDisk: allocSize, logical: dataLength,
            fileid: fileid, linkCount: linkCount, mtime: mtime))
        return length
    }

    private func listViaLstat(dirPath: String, _ handler: (RawEntry) throws -> Void) throws {
        guard let dirp = opendir(dirPath) else { stats.permissionDenied += 1; return }
        defer { closedir(dirp) }

        var processed = 0
        while let entp = readdir(dirp) {
            let cname = Self.entryName(entp)
            if cname == "." || cname == ".." { continue }
            let childPath = Self.join(dirPath, cname)

            var cst = stat()
            guard lstat(childPath, &cst) == 0 else { continue }   // raced/vanished
            let mode = Self.modeType(cst)
            let objType: Int32 = mode == Self.typeDir ? Self.objDir
                : (mode == Self.typeLink ? Self.objLink : (mode == Self.typeReg ? Self.objReg : 0))

            try handler(RawEntry(
                name: cname, objType: objType, sizeOnDisk: Int64(cst.st_blocks) * 512,
                logical: Int64(cst.st_size), fileid: UInt64(cst.st_ino),
                linkCount: UInt32(cst.st_nlink), mtime: Self.mtime(cst)))

            processed += 1
            if processed % 512 == 0 { try checkCancellation() }
        }
    }

    // MARK: Helpers

    private func checkCancellation() throws {
        if shared.cancellation?.isCancelled == true { throw CancellationError() }
    }

    private func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return packageExtensions.contains(ext)
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    // `vnode` object types (fsobj_type_t) as returned by ATTR_CMN_OBJTYPE.
    static let objReg: Int32 = 1   // VREG
    static let objDir: Int32 = 2   // VDIR
    static let objLink: Int32 = 5  // VLNK

    // getattrlistbulk attribute bits (stable kernel ABI; see <sys/attr.h>).
    static let cmnReturned: UInt32  = 0x8000_0000   // ATTR_CMN_RETURNED_ATTRS
    static let cmnName: UInt32      = 0x0000_0001   // ATTR_CMN_NAME
    static let cmnObjType: UInt32   = 0x0000_0008   // ATTR_CMN_OBJTYPE
    static let cmnModtime: UInt32   = 0x0000_0400   // ATTR_CMN_MODTIME
    static let cmnFileID: UInt32    = 0x0200_0000   // ATTR_CMN_FILEID
    static let cmnError: UInt32     = 0x4000_0000   // ATTR_CMN_ERROR
    static let fileLinkCount: UInt32 = 0x0000_0001  // ATTR_FILE_LINKCOUNT
    static let fileAllocSize: UInt32 = 0x0000_0004  // ATTR_FILE_ALLOCSIZE
    static let fileDataLength: UInt32 = 0x0000_0200 // ATTR_FILE_DATALENGTH
    static let packInvalAttrs: UInt64 = 0x0000_0008 // FSOPT_PACK_INVAL_ATTRS

    private static let typeMask = mode_t(S_IFMT)
    static let typeDir = mode_t(S_IFDIR)
    static let typeLink = mode_t(S_IFLNK)
    static let typeReg = mode_t(S_IFREG)

    static func modeType(_ st: stat) -> mode_t { st.st_mode & typeMask }

    static func mtime(_ st: stat) -> Date? {
        let ts = st.st_mtimespec
        if ts.tv_sec == 0 && ts.tv_nsec == 0 { return nil }
        return Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000)
    }

    static func rootName(for path: String) -> String {
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
