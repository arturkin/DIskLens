import Foundation

/// Persists scan runs to disk: a JSON index of `RunMetadata` plus one compressed
/// tree blob per run. Enforces a retention cap.
///
/// `baseDir` is injectable so tests can run against a temporary directory.
/// `@unchecked Sendable`: file I/O is stateless and safe to call from any task;
/// `maxRuns` is only ever mutated on the main actor.
public final class RunStore: @unchecked Sendable {
    public enum StoreError: Error {
        case runNotFound(UUID)
    }

    public let baseDir: URL
    public var maxRuns: Int

    /// - Parameter baseDir: Root directory for storage. Defaults to
    ///   `~/Library/Application Support/DiskLens`.
    public init(baseDir: URL? = nil, maxRuns: Int = 10) {
        self.baseDir = baseDir ?? RunStore.defaultBaseDirectory()
        self.maxRuns = maxRuns
    }

    public static func defaultBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("DiskLens", isDirectory: true)
    }

    // MARK: - Paths

    private var indexURL: URL { baseDir.appendingPathComponent("index.json") }
    private var runsDir: URL { baseDir.appendingPathComponent("runs", isDirectory: true) }
    private func treeURL(_ id: UUID) -> URL {
        runsDir.appendingPathComponent("\(id.uuidString).tree")
    }

    // MARK: - Index

    /// Run metadata, newest first.
    public func loadIndex() throws -> [RunMetadata] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let data = try Data(contentsOf: indexURL)
        let metas = try Self.jsonDecoder.decode([RunMetadata].self, from: data)
        return metas.sorted { $0.date > $1.date }
    }

    private func writeIndex(_ metas: [RunMetadata]) throws {
        try ensureDirectories()
        let sorted = metas.sorted { $0.date > $1.date }
        let data = try Self.jsonEncoder.encode(sorted)
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Mutations

    /// Persists a tree + metadata, updates the index, and prunes beyond `maxRuns`.
    public func save(tree: FileTree, metadata: RunMetadata) throws {
        try ensureDirectories()
        let blob = try TreeCodec.encode(tree)
        try blob.write(to: treeURL(metadata.id), options: .atomic)

        var index = try loadIndex().filter { $0.id != metadata.id }
        index.append(metadata)
        index.sort { $0.date > $1.date }

        // Prune oldest beyond the cap, deleting their blobs.
        if index.count > maxRuns {
            for stale in index[maxRuns...] {
                try? FileManager.default.removeItem(at: treeURL(stale.id))
            }
            index = Array(index.prefix(maxRuns))
        }
        try writeIndex(index)
    }

    public func loadTree(id: UUID) throws -> FileTree {
        let url = treeURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.runNotFound(id)
        }
        let data = try Data(contentsOf: url)
        return try TreeCodec.decode(data)
    }

    public func deleteRun(id: UUID) throws {
        try? FileManager.default.removeItem(at: treeURL(id))
        let index = try loadIndex().filter { $0.id != id }
        try writeIndex(index)
    }

    // MARK: - Helpers

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
