import SwiftUI
import DiskLensCore

enum ScanPhase: Equatable {
    case idle
    case scanning(ScanProgress)
    case failed(String)
}

/// Central app state: the loaded tree, navigation focus, run history, and the
/// in-flight scan. Main-actor isolated; the scan itself runs in the background
/// via `ScanCoordinator`.
@MainActor
@Observable
final class AppModel {
    let store: RunStore

    var runs: [RunMetadata] = []
    var selectedRunID: UUID?

    /// The currently displayed tree and the navigation stack into it.
    private(set) var tree: FileTree?
    var focusPath: [FileNode] = []
    var hovered: FileNode?

    var phase: ScanPhase = .idle
    var lastStats: ScanStats?

    /// View preferences shared across charts (filled out in later milestones).
    var vizKind: VizKind = .sunburst

    private var cancellation: ScanCancellation?

    init(store: RunStore = RunStore()) {
        self.store = store
    }

    // MARK: Derived

    var focus: FileNode? { focusPath.last }
    var root: FileNode? { focusPath.first }
    var isScanning: Bool { if case .scanning = phase { true } else { false } }
    var canGoUp: Bool { focusPath.count > 1 }
    var selectedRun: RunMetadata? { runs.first { $0.id == selectedRunID } }

    // MARK: Lifecycle

    func bootstrap() {
        reloadRuns()
        if let mostRecent = runs.first {
            select(runID: mostRecent.id)
        }
    }

    func reloadRuns() {
        runs = (try? store.loadIndex()) ?? []
    }

    func select(runID: UUID) {
        guard let tree = try? store.loadTree(id: runID) else { return }
        selectedRunID = runID
        lastStats = nil
        present(tree: tree)
    }

    private func present(tree: FileTree) {
        self.tree = tree
        self.focusPath = [tree.root]
        self.hovered = nil
    }

    // MARK: Navigation

    func drill(into node: FileNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        focusPath.append(node)
        hovered = nil
    }

    func focus(toDepth index: Int) {
        guard index >= 0, index < focusPath.count else { return }
        focusPath = Array(focusPath.prefix(index + 1))
        hovered = nil
    }

    func goUp() {
        guard canGoUp else { return }
        focusPath.removeLast()
        hovered = nil
    }

    // MARK: Scanning

    func startScan(root: URL, mode: ScanMode = .user) {
        guard !isScanning else { return }
        let options = ScanOptions(root: root)
        let token = ScanCancellation()
        cancellation = token
        phase = .scanning(ScanProgress())
        let started = Date()

        Task {
            do {
                let result = try await ScanCoordinator.run(options, cancellation: token) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isScanning else { return }
                        self.phase = .scanning(progress)
                    }
                }
                finishScan(result, root: root, mode: mode, started: started)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        cancellation?.cancel()
    }

    // MARK: Cleanup — collection bag + trash

    struct CollectedItem: Identifiable {
        let id: ObjectIdentifier
        let node: FileNode
        let url: URL
        var name: String { node.name }
        var size: Int64 { node.sizeOnDisk }
    }

    private(set) var bag: [CollectedItem] = []
    var bagTotalSize: Int64 { bag.reduce(0) { $0 + $1.size } }

    /// Trash confirmation state (driven by the UI).
    var trashCandidates: [FileNode] = []
    var isConfirmingTrash = false
    var lastTrashMessage: String?

    /// Whether file actions (reveal/collect/trash) make sense for a node.
    func actionable(_ node: FileNode) -> Bool {
        guard let tree else { return false }
        if node === tree.root { return false }
        if node.flags.contains(.aggregatedSmallFiles) { return false }
        return true
    }

    func isCollected(_ node: FileNode) -> Bool {
        bag.contains { $0.id == ObjectIdentifier(node) }
    }

    func toggleCollect(_ node: FileNode) {
        let id = ObjectIdentifier(node)
        if let index = bag.firstIndex(where: { $0.id == id }) {
            bag.remove(at: index)
        } else if actionable(node), let url = url(for: node) {
            bag.append(CollectedItem(id: id, node: node, url: url))
        }
    }

    func clearBag() { bag.removeAll() }

    func reveal(_ node: FileNode) {
        if let url = url(for: node) { TrashService.reveal(url) }
    }

    /// Absolute URL of a node, by reconstructing its name path from the tree root.
    func url(for node: FileNode) -> URL? {
        guard let tree else { return nil }
        return NodeLocator.absoluteURL(scannedRoot: tree.scannedRoot, root: tree.root, target: node)
    }

    // MARK: Trash flow (confirmation → perform → prune → persist)

    func requestTrash(_ nodes: [FileNode]) {
        let candidates = nodes.filter { actionable($0) }
        guard !candidates.isEmpty else { return }
        trashCandidates = candidates
        isConfirmingTrash = true
    }

    func requestTrashBag() {
        requestTrash(bag.map(\.node))
    }

    func confirmTrash() {
        performTrash(trashCandidates)
        trashCandidates = []
        isConfirmingTrash = false
    }

    private func performTrash(_ nodes: [FileNode]) {
        var removed = Set<ObjectIdentifier>()
        var reclaimed: Int64 = 0
        var failures = 0

        for node in nodes {
            guard actionable(node), let url = url(for: node),
                  url.lastPathComponent == node.name else { failures += 1; continue }
            do {
                try TrashService.trash(url)
                removed.insert(ObjectIdentifier(node))
                reclaimed += node.sizeOnDisk
            } catch {
                failures += 1
            }
        }

        if !removed.isEmpty, let tree {
            applyPruned(TreePruner.prune(tree, removing: removed))
        }
        bag.removeAll { removed.contains($0.id) }

        var message = "Moved \(removed.count) item\(removed.count == 1 ? "" : "s") to Trash · \(Format.bytes(reclaimed)) reclaimed"
        if failures > 0 { message += " · \(failures) failed" }
        lastTrashMessage = message
    }

    /// Swap in a pruned tree, re-derive the focus path by name, and persist.
    private func applyPruned(_ pruned: FileTree) {
        let focusNames = focusPath.dropFirst().map(\.name)
        tree = pruned
        var path: [FileNode] = [pruned.root]
        var cursor = pruned.root
        for name in focusNames {
            guard let next = cursor.children.first(where: { $0.name == name }) else { break }
            path.append(next)
            cursor = next
        }
        focusPath = path
        hovered = nil

        if let id = selectedRunID, let meta = runs.first(where: { $0.id == id }) {
            let updated = RunMetadata(
                id: id, date: meta.date, scannedRoot: meta.scannedRoot, mode: meta.mode,
                volumeName: meta.volumeName, totalSize: pruned.root.sizeOnDisk,
                fileCount: Int(pruned.root.fileCount), durationMs: meta.durationMs,
                appVersion: meta.appVersion)
            try? store.save(tree: pruned, metadata: updated)
            reloadRuns()
            selectedRunID = id
        }
    }

    private func finishScan(_ result: DiskScanner.Result, root: URL, mode: ScanMode, started: Date) {
        let meta = RunMetadata(
            date: Date(),
            scannedRoot: result.tree.scannedRoot,
            mode: mode,
            volumeName: Self.volumeName(for: root),
            totalSize: result.tree.root.sizeOnDisk,
            fileCount: Int(result.tree.root.fileCount),
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            appVersion: Self.appVersion
        )
        try? store.save(tree: result.tree, metadata: meta)
        lastStats = result.stats
        reloadRuns()
        selectedRunID = meta.id
        present(tree: result.tree)
        phase = .idle
    }

    // MARK: Helpers

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private static func volumeName(for url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }
}
