import Foundation
import Testing
@testable import DiskLensCore

struct RunStoreTests {
    /// Fresh store rooted in a unique temp dir; caller cleans up.
    private func makeStore(maxRuns: Int = 10) -> (RunStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskLensTests-\(UUID().uuidString)", isDirectory: true)
        return (RunStore(baseDir: tmp, maxRuns: maxRuns), tmp)
    }

    @Test("empty store returns an empty index")
    func emptyIndex() throws {
        let (store, tmp) = makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(try store.loadIndex().isEmpty)
    }

    @Test("save then load round-trips both metadata and tree")
    func saveLoad() throws {
        let (store, tmp) = makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tree = Fixtures.sampleTree()
        let meta = Fixtures.metadata(date: Date(timeIntervalSince1970: 1000), total: 5120, files: 3)
        try store.save(tree: tree, metadata: meta)

        let index = try store.loadIndex()
        #expect(index.count == 1)
        #expect(index[0].id == meta.id)
        #expect(index[0].totalSize == 5120)

        let loaded = try store.loadTree(id: meta.id)
        #expect(assertTreesEqual(loaded.root, tree.root))
    }

    @Test("index is sorted newest first")
    func newestFirst() throws {
        let (store, tmp) = makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let older = Fixtures.metadata(date: Date(timeIntervalSince1970: 1000), total: 1, files: 1)
        let newer = Fixtures.metadata(date: Date(timeIntervalSince1970: 2000), total: 2, files: 1)
        try store.save(tree: Fixtures.sampleTree(), metadata: older)
        try store.save(tree: Fixtures.sampleTree(), metadata: newer)

        let index = try store.loadIndex()
        #expect(index.map(\.id) == [newer.id, older.id])
    }

    @Test("retention prunes oldest runs beyond maxRuns and deletes their blobs")
    func retention() throws {
        let (store, tmp) = makeStore(maxRuns: 2)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var metas: [RunMetadata] = []
        for i in 0..<4 {
            let m = Fixtures.metadata(date: Date(timeIntervalSince1970: Double(i * 1000)), total: Int64(i), files: 1)
            metas.append(m)
            try store.save(tree: Fixtures.sampleTree(), metadata: m)
        }

        let index = try store.loadIndex()
        #expect(index.count == 2)
        // Newest two survive (i=3, i=2); oldest two pruned.
        #expect(Set(index.map(\.id)) == Set([metas[3].id, metas[2].id]))
        // Pruned tree blobs are gone.
        #expect(throws: (any Error).self) { _ = try store.loadTree(id: metas[0].id) }
    }

    @Test("deleteRun removes metadata and blob")
    func deleteRun() throws {
        let (store, tmp) = makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let meta = Fixtures.metadata(date: Date(), total: 1, files: 1)
        try store.save(tree: Fixtures.sampleTree(), metadata: meta)
        try store.deleteRun(id: meta.id)

        #expect(try store.loadIndex().isEmpty)
        #expect(throws: (any Error).self) { _ = try store.loadTree(id: meta.id) }
    }

    @Test("loadTree migrates a legacy plist blob to the current fast format")
    func migratesLegacyBlobOnLoad() throws {
        let (store, tmp) = makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tree = Fixtures.sampleTree()
        let meta = Fixtures.metadata(date: Date(timeIntervalSince1970: 1000), total: 5120, files: 3)

        // Seed the store with a legacy-format blob (zlib of a binary plist, no
        // header) while keeping the index consistent via the normal save path.
        try store.save(tree: tree, metadata: meta)
        let blobURL = tmp.appendingPathComponent("runs/\(meta.id.uuidString).tree")
        let legacy = try (PropertyListEncoder.binary().encode(tree) as NSData).compressed(using: .zlib) as Data
        try legacy.write(to: blobURL, options: .atomic)
        #expect(!TreeCodec.isCurrentFormat(try Data(contentsOf: blobURL)))

        // Loading it returns the right tree and rewrites the blob in place.
        let loaded = try store.loadTree(id: meta.id)
        #expect(assertTreesEqual(loaded.root, tree.root))
        #expect(TreeCodec.isCurrentFormat(try Data(contentsOf: blobURL)))

        // The migrated blob still decodes correctly.
        #expect(assertTreesEqual(try store.loadTree(id: meta.id).root, tree.root))
    }

    @Test("a new RunStore instance sees previously persisted runs")
    func persistsAcrossInstances() throws {
        let (store, tmp) = makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let meta = Fixtures.metadata(date: Date(), total: 7, files: 2)
        try store.save(tree: Fixtures.sampleTree(), metadata: meta)

        let reopened = RunStore(baseDir: tmp)
        let index = try reopened.loadIndex()
        #expect(index.count == 1)
        #expect(index[0].id == meta.id)
    }
}
