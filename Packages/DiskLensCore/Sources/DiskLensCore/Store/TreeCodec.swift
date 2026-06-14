import Foundation

/// Serializes a `FileTree` to a compact, compressed blob and back.
///
/// Encoding: a custom preorder/varint binary stream → zlib compression, prefixed
/// with a 4-byte magic+version header. Decoding directly walks the byte buffer
/// into `FileNode`s, avoiding the intermediate `NSDictionary`/`NSArray` object
/// graph that `PropertyListDecoder` builds — on a whole-disk scan (millions of
/// nodes) that cuts load time from ~50s to a few seconds and roughly halves the
/// on-disk size.
///
/// Blobs written before this format had no header (a bare zlib stream of a binary
/// plist); `decode` detects the absence of the magic and falls back to the legacy
/// path, so old runs keep loading.
public enum TreeCodec {
    public enum CodecError: Error {
        case decompressionFailed
        /// The byte stream ended mid-field (corrupt or truncated blob).
        case truncated
    }

    /// `DLT` + format version. Distinct from a raw zlib stream's first byte
    /// (`0x78`), so legacy blobs are unambiguously identifiable.
    private static let magic: [UInt8] = [0x44, 0x4C, 0x54, 0x01]   // "DLT\u{01}"

    /// Whether `blob` is written in the current (fast) format rather than the
    /// legacy plist format. Used by `RunStore` to self-heal old runs on load.
    public static func isCurrentFormat(_ blob: Data) -> Bool {
        blob.starts(with: magic)
    }

    // MARK: - Encode

    public static func encode(_ tree: FileTree) throws -> Data {
        var out = [UInt8]()
        out.reserveCapacity(1 << 16)
        appendString(tree.scannedRoot, &out)
        encodeNode(tree.root, &out)

        let compressed = try (Data(out) as NSData).compressed(using: .zlib) as Data
        var blob = Data(magic)
        blob.append(compressed)
        return blob
    }

    private static func encodeNode(_ node: FileNode, _ out: inout [UInt8]) {
        appendString(node.name, &out)
        // Pack the directory bit and the flags into one varint (1 byte in practice).
        let meta = UInt64(node.isDirectory ? 1 : 0)
            | (UInt64(UInt32(bitPattern: node.flags.rawValue)) << 1)
        appendVarint(meta, &out)
        appendVarint(UInt64(bitPattern: node.sizeOnDisk), &out)
        appendVarint(UInt64(bitPattern: node.logicalSize), &out)
        appendVarint(UInt64(UInt32(bitPattern: node.fileCount)), &out)
        if let modified = node.modified {
            out.append(1)
            var bits = modified.timeIntervalSinceReferenceDate.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        } else {
            out.append(0)
        }
        appendVarint(UInt64(node.children.count), &out)
        for child in node.children { encodeNode(child, &out) }
    }

    @inline(__always)
    private static func appendVarint(_ value: UInt64, _ out: inout [UInt8]) {
        var x = value
        while x >= 0x80 {
            out.append(UInt8(truncatingIfNeeded: x) | 0x80)
            x >>= 7
        }
        out.append(UInt8(truncatingIfNeeded: x))
    }

    @inline(__always)
    private static func appendString(_ string: String, _ out: inout [UInt8]) {
        let bytes = Array(string.utf8)
        appendVarint(UInt64(bytes.count), &out)
        out.append(contentsOf: bytes)
    }

    // MARK: - Decode

    public static func decode(_ data: Data) throws -> FileTree {
        guard isCurrentFormat(data) else { return try decodeLegacy(data) }

        let payload = try decompress(data.subdata(in: magic.count..<data.count))
        guard !payload.isEmpty else { throw CodecError.truncated }
        return try payload.withUnsafeBytes { raw -> FileTree in
            let buffer = raw.bindMemory(to: UInt8.self)
            guard let base = buffer.baseAddress else { throw CodecError.truncated }
            var reader = ByteReader(base: base, count: buffer.count)
            let scannedRoot = try reader.string()
            let root = try decodeNode(&reader)
            return FileTree(root: root, scannedRoot: scannedRoot)
        }
    }

    /// Original format: a zlib-compressed binary property list, no header.
    private static func decodeLegacy(_ data: Data) throws -> FileTree {
        let decompressed = try decompress(data)
        return try PropertyListDecoder().decode(FileTree.self, from: decompressed)
    }

    private static func decompress(_ data: Data) throws -> Data {
        do {
            return try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw CodecError.decompressionFailed
        }
    }

    private static func decodeNode(_ reader: inout ByteReader) throws -> FileNode {
        let name = try reader.string()
        let meta = try reader.varint()
        let isDirectory = (meta & 1) != 0
        let flags = NodeFlags(rawValue: Int32(truncatingIfNeeded: meta >> 1))
        let sizeOnDisk = Int64(bitPattern: try reader.varint())
        let logicalSize = Int64(bitPattern: try reader.varint())
        let fileCount = Int32(bitPattern: UInt32(truncatingIfNeeded: try reader.varint()))
        let modified: Date? = try reader.byte() == 1
            ? Date(timeIntervalSinceReferenceDate: try reader.double())
            : nil

        let childCount = Int(try reader.varint())
        // Each child needs at least one byte, so a count beyond the remaining
        // bytes is corrupt — reject it before reserving capacity.
        guard childCount >= 0, childCount <= reader.remaining else { throw CodecError.truncated }
        var children = [FileNode]()
        children.reserveCapacity(childCount)
        for _ in 0..<childCount { children.append(try decodeNode(&reader)) }

        return FileNode(
            name: name, isDirectory: isDirectory, sizeOnDisk: sizeOnDisk,
            logicalSize: logicalSize, modified: modified, fileCount: fileCount,
            flags: flags, children: children)
    }
}

/// A bounds-checked cursor over a raw byte buffer. Reads throw `truncated`
/// rather than crashing on a corrupt or short blob.
private struct ByteReader {
    let base: UnsafePointer<UInt8>
    let count: Int
    var index = 0

    var remaining: Int { count - index }

    @inline(__always)
    mutating func byte() throws -> UInt8 {
        guard index < count else { throw TreeCodec.CodecError.truncated }
        defer { index += 1 }
        return base[index]
    }

    @inline(__always)
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < count else { throw TreeCodec.CodecError.truncated }
            let b = base[index]
            index += 1
            result |= UInt64(b & 0x7f) << shift
            if b < 0x80 { return result }
            shift += 7
            guard shift < 64 else { throw TreeCodec.CodecError.truncated }
        }
    }

    @inline(__always)
    mutating func string() throws -> String {
        let length = Int(try varint())
        guard length >= 0, length <= remaining else { throw TreeCodec.CodecError.truncated }
        let s = String(decoding: UnsafeBufferPointer(start: base + index, count: length), as: UTF8.self)
        index += length
        return s
    }

    @inline(__always)
    mutating func double() throws -> Double {
        guard remaining >= 8 else { throw TreeCodec.CodecError.truncated }
        var bits: UInt64 = 0
        withUnsafeMutableBytes(of: &bits) {
            $0.copyMemory(from: UnsafeRawBufferPointer(start: base + index, count: 8))
        }
        index += 8
        return Double(bitPattern: UInt64(littleEndian: bits))
    }
}
