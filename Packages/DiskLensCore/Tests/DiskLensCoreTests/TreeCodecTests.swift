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
}

extension PropertyListEncoder {
    static func binary() -> PropertyListEncoder {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return e
    }
}
