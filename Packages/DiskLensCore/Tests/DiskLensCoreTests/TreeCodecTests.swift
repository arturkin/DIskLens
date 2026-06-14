import Foundation
import Testing
@testable import DiskLensCore

struct TreeCodecTests {
    @Test("encode then decode reproduces the tree exactly")
    func roundTrip() throws {
        let tree = Fixtures.sampleTree()
        let data = try TreeCodec.encode(tree)
        let decoded = try TreeCodec.decode(data)

        #expect(decoded.scannedRoot == tree.scannedRoot)
        #expect(assertTreesEqual(decoded.root, tree.root))
    }

    @Test("encoded blob is smaller than the raw binary plist (compression works)")
    func compresses() throws {
        let tree = Fixtures.sampleTree()
        let compressed = try TreeCodec.encode(tree)
        let rawPlist = try PropertyListEncoder.binary().encode(tree)
        // Tiny trees may not always shrink, but a tree padded with repetition must.
        let padded = Fixtures.sampleTree(root: String(repeating: "/deep/path", count: 200))
        let paddedCompressed = try TreeCodec.encode(padded)
        let paddedRaw = try PropertyListEncoder.binary().encode(padded)
        #expect(paddedCompressed.count < paddedRaw.count)
        #expect(!compressed.isEmpty)
        #expect(!rawPlist.isEmpty)
    }

    @Test("decoding garbage throws rather than crashing")
    func decodeGarbage() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        #expect(throws: (any Error).self) {
            _ = try TreeCodec.decode(garbage)
        }
    }

    @Test("encode emits the fast current format (not a bare legacy plist blob)")
    func encodeUsesCurrentFormat() throws {
        let blob = try TreeCodec.encode(Fixtures.sampleTree())
        #expect(TreeCodec.isCurrentFormat(blob))

        // A legacy blob (zlib of a binary plist) must NOT be mistaken for current.
        let legacy = try Self.legacyBlob(Fixtures.sampleTree())
        #expect(!TreeCodec.isCurrentFormat(legacy))
    }

    @Test("legacy plist+zlib blobs still decode (backward compatibility)")
    func decodesLegacyBlob() throws {
        let tree = Fixtures.sampleTree()
        let legacy = try Self.legacyBlob(tree)
        let decoded = try TreeCodec.decode(legacy)
        #expect(decoded.scannedRoot == tree.scannedRoot)
        #expect(assertTreesEqual(decoded.root, tree.root))
    }

    @Test("round-trips a large, wide, deep tree with varied fields")
    func largeTreeRoundTrip() throws {
        let tree = Self.bigTree()
        let decoded = try TreeCodec.decode(try TreeCodec.encode(tree))
        #expect(decoded.scannedRoot == tree.scannedRoot)
        #expect(assertTreesEqual(decoded.root, tree.root))
    }

    @Test("a truncated current-format blob throws rather than crashing")
    func decodeTruncatedCurrent() throws {
        let blob = try TreeCodec.encode(Self.bigTree())
        #expect(throws: (any Error).self) {
            _ = try TreeCodec.decode(blob.prefix(blob.count / 2))
        }
    }

    // MARK: - Helpers

    /// Reproduces the original on-disk format: a zlib-compressed binary plist with
    /// no magic header. Used to prove decode stays backward compatible.
    private static func legacyBlob(_ tree: FileTree) throws -> Data {
        let plist = try PropertyListEncoder.binary().encode(tree)
        return try (plist as NSData).compressed(using: .zlib) as Data
    }

    /// A tree with enough breadth/depth and field variety (unicode names, large
    /// sizes forcing multi-byte varints, all flags, present and absent dates) to
    /// exercise the binary codec's edge cases.
    private static func bigTree() -> FileTree {
        func leaf(_ i: Int) -> FileNode {
            FileNode(
                name: "файл-\(i)-🗂.bin", isDirectory: false,
                sizeOnDisk: Int64(i) * 4096 + 1, logicalSize: Int64(i) * 4093,
                modified: i.isMultiple(of: 3) ? nil : Date(timeIntervalSinceReferenceDate: Double(i) * 1.5),
                fileCount: 1,
                flags: i.isMultiple(of: 5) ? [.symlink, .package] : [])
        }
        var dirs: [FileNode] = []
        for d in 0..<40 {
            let kids = (0..<200).map { leaf(d * 200 + $0) }
            let size = kids.reduce(Int64(0)) { $0 + $1.sizeOnDisk }
            dirs.append(FileNode(
                name: "dir\(d)", isDirectory: true, sizeOnDisk: size, logicalSize: size,
                modified: nil, fileCount: Int32(kids.count),
                flags: d == 0 ? [.permissionDenied] : [.mountPoint], children: kids))
        }
        let total = dirs.reduce(Int64(0)) { $0 + $1.sizeOnDisk }
        let root = FileNode(
            name: "root", isDirectory: true, sizeOnDisk: 9_876_543_210_123,
            logicalSize: total, modified: Date(timeIntervalSinceReferenceDate: 12345),
            fileCount: 8000, children: dirs)
        return FileTree(root: root, scannedRoot: "/Volumes/Big Disk")
    }
}

extension PropertyListEncoder {
    static func binary() -> PropertyListEncoder {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return e
    }
}
