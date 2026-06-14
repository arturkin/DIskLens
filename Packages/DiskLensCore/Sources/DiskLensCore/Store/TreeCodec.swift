import Foundation

/// Serializes a `FileTree` to a compact, compressed blob and back.
///
/// Encoding: binary property list → zlib compression. Compact enough for
/// per-run on-disk snapshots; a custom preorder/varint format is a noted future
/// optimization if blobs grow too large.
public enum TreeCodec {
    public enum CodecError: Error {
        case decompressionFailed
    }

    public static func encode(_ tree: FileTree) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plist = try encoder.encode(tree)
        let compressed = try (plist as NSData).compressed(using: .zlib)
        return compressed as Data
    }

    public static func decode(_ data: Data) throws -> FileTree {
        let decompressed: Data
        do {
            decompressed = try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw CodecError.decompressionFailed
        }
        return try PropertyListDecoder().decode(FileTree.self, from: decompressed)
    }
}
