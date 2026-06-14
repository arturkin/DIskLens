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
    var isLoadingRun = false

    /// View preferences shared across charts (filled out in later milestones).
    var vizKind: VizKind = .sunburst

    private var cancellation: ScanCancellation?
    private let elevation: ElevationService = OnDemandElevationService()

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
        store.maxRuns = Preferences.maxRuns
        reloadRuns()
        if let mostRecent = runs.first {
            select(runID: mostRecent.id)
            // Auto-rescan only user-mode runs. An admin run would pop the
            // privilege prompt on every launch — admin scans stay on-demand.
            if Preferences.autoRescanOnLaunch, mostRecent.mode == .user {
                startScan(root: URL(filePath: mostRecent.scannedRoot), mode: .user)
            }
        }
    }

    func reloadRuns() {
        runs = (try? store.loadIndex()) ?? []
    }

    /// Loads a run's tree off the main actor (large blobs take seconds to decode).
    func select(runID: UUID) {
        selectedRunID = runID
        lastStats = nil
        isLoadingRun = true
        let store = self.store
        Task {
            let tree = await Task.detached { try? store.loadTree(id: runID) }.value
            guard selectedRunID == runID else { return }   // superseded by another selection
            isLoadingRun = false
            if let tree { present(tree: tree) }
        }
    }

    func deleteRun(_ id: UUID) {
        try? store.deleteRun(id: id)
        let wasSelected = selectedRunID == id
        reloadRuns()
        if wasSelected {
            if let next = runs.first {
                select(runID: next.id)
            } else {
                tree = nil
                focusPath = []
                selectedRunID = nil
                hovered = nil
                diff = nil
            }
        }
        // If the deleted run was the compare baseline, it now dangles; drop it and
        // recompute against a fresh default so the diff doesn't show a phantom run.
        if baselineRunID == id {
            baselineRunID = nil
            refreshCompareForCurrentRun()
        }
    }

    private func present(tree: FileTree) {
        self.tree = tree
        self.focusPath = [tree.root]
        self.hovered = nil
        // The collection bag holds node identities from the *previous* tree; a new
        // scan or a switch to another run invalidates them (a stale node can't be
        // located in the new tree, so trashing it would silently fail). Clear it.
        // A prune (applyPruned) deliberately does NOT go through present(): it
        // preserves identities for untouched branches, so the bag stays valid there.
        self.bag.removeAll()
        refreshCompareForCurrentRun()
    }

    // MARK: Navigation

    func drill(into node: FileNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        hovered = nil
        withAnimation(.easeInOut(duration: 0.28)) { focusPath.append(node) }
    }

    func focus(toDepth index: Int) {
        guard index >= 0, index < focusPath.count, index != focusPath.count - 1 else { return }
        hovered = nil
        withAnimation(.easeInOut(duration: 0.28)) { focusPath = Array(focusPath.prefix(index + 1)) }
    }

    func goUp() {
        guard canGoUp else { return }
        hovered = nil
        withAnimation(.easeInOut(duration: 0.28)) { focusPath.removeLast() }
    }

    // MARK: Scanning

    /// Whether the in-flight scan can be cancelled (user scans only; the admin
    /// scan runs in a separate root process we can't interrupt).
    var canCancelScan: Bool { isScanning && cancellation != nil }

    func startScan(root: URL, mode: ScanMode = .user) {
        guard !isScanning else { return }
        let options = Preferences.scanOptions(root: root)
        phase = .scanning(ScanProgress())
        let started = Date()

        if mode == .admin {
            cancellation = nil
            let elevation = self.elevation
            Task {
                do {
                    let tree = try await elevation.runPrivilegedScan(options: options) { progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.isScanning else { return }
                            self.phase = .scanning(progress)
                        }
                    }
                    finishScan(tree: tree, stats: nil, root: root, mode: .admin, started: started)
                } catch let error as ElevationError {
                    phase = (error == .cancelled) ? .idle : .failed(error.localizedDescription)
                } catch {
                    phase = .failed(error.localizedDescription)
                }
            }
        } else {
            let token = ScanCancellation()
            cancellation = token
            // Switch the main view to a live preview that fills in as each
            // top-level subtree lands, so the chart is usable mid-scan instead of
            // frozen on stale data. `gen` fences out late callbacks from a scan
            // that has since finished, been cancelled, or been superseded.
            let gen = beginLivePreview(root: root)
            Task {
                do {
                    let result = try await ScanCoordinator.run(
                        options, cancellation: token,
                        progress: { progress in
                            Task { @MainActor [weak self] in
                                guard let self, self.scanGen == gen, self.isScanning else { return }
                                self.phase = .scanning(progress)
                            }
                        },
                        partial: { node in
                            Task { @MainActor [weak self] in
                                guard let self, self.scanGen == gen, self.isScanning else { return }
                                self.appendLiveChild(node)
                            }
                        })
                    finishScan(tree: result.tree, stats: result.stats, root: root, mode: .user, started: started)
                } catch is CancellationError {
                    endLivePreview()
                    phase = .idle
                } catch {
                    endLivePreview()
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Live progressive preview (user scans)

    /// Generation of the in-flight scan; bumped per `startScan` so stale async
    /// callbacks can no-op.
    private var scanGen = 0
    /// Top-level subtrees received so far during the live preview.
    private var liveChildren: [FileNode] = []
    private var liveRootName = ""
    private var liveScannedRoot = ""
    /// What was on screen before the scan, restored if it is cancelled or fails.
    private var stash: (tree: FileTree?, focus: [FileNode], bag: [CollectedItem])?

    /// Begins a scan's live preview: stashes the current view, then shows an empty
    /// root that `appendLiveChild` grows. Returns the new scan generation.
    private func beginLivePreview(root: URL) -> Int {
        scanGen += 1
        stash = (tree, focusPath, bag)
        liveChildren = []
        liveScannedRoot = root.standardizedFileURL.path
        liveRootName = Self.rootName(for: root)
        hovered = nil
        diff = nil                       // palette-color the preview; real diff recomputes on finish
        presentLiveRoot()
        bag.removeAll()                  // identities belong to the stashed tree now
        return scanGen
    }

    /// Folds a freshly-finished top-level subtree into the live preview.
    private func appendLiveChild(_ node: FileNode) {
        liveChildren.append(node)
        presentLiveRoot()
    }

    /// Rebuilds the synthetic live root from `liveChildren` and shows it at the
    /// root focus. Cheap (top-level children only); does not touch the bag/diff so
    /// it can run on every subtree completion. Loose root-level files are absent
    /// until the authoritative tree arrives in `finishScan`.
    private func presentLiveRoot() {
        let sorted = liveChildren.sorted { $0.sizeOnDisk > $1.sizeOnDisk }
        var total: Int64 = 0, logical: Int64 = 0, files: Int32 = 0
        for c in sorted { total += c.sizeOnDisk; logical += c.logicalSize; files += c.fileCount }
        let live = FileNode(
            name: liveRootName, isDirectory: true, sizeOnDisk: total,
            logicalSize: logical, modified: nil, fileCount: files, flags: [], children: sorted)
        tree = FileTree(root: live, scannedRoot: liveScannedRoot)
        focusPath = [live]
    }

    /// Restores the stashed pre-scan view (used when a scan is cancelled or fails).
    private func endLivePreview() {
        liveChildren = []
        guard let stash else {
            tree = nil; focusPath = []; hovered = nil; diff = nil; return
        }
        tree = stash.tree
        focusPath = stash.focus
        bag = stash.bag
        hovered = nil
        self.stash = nil
        refreshCompareForCurrentRun()
    }

    func cancelScan() {
        cancellation?.cancel()
    }

    /// Whether there's a selected run we can re-scan.
    var canRescan: Bool { !isScanning && selectedRun != nil }

    /// Re-runs the currently selected run's scan (same root + privilege mode).
    func rescanCurrent() {
        guard let run = selectedRun else { return }
        startScan(root: URL(filePath: run.scannedRoot), mode: run.mode == .admin ? .admin : .user)
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
        // Never offer destructive actions on a volume mount point or on a
        // directory we couldn't even read (often a SIP/system path). Trashing
        // either is nonsensical and a needless way to harm a mounted volume.
        if node.flags.contains(.mountPoint) { return false }
        if node.flags.contains(.permissionDenied) { return false }
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

    /// Synchronous tree load, used only by the headless snapshot mode.
    func loadSynchronouslyForSnapshot(runID: UUID) {
        if let tree = try? store.loadTree(id: runID) {
            selectedRunID = runID
            present(tree: tree)
        }
    }

    private func finishScan(tree: FileTree, stats: ScanStats?, root: URL, mode: ScanMode, started: Date) {
        store.maxRuns = Preferences.maxRuns
        let meta = RunMetadata(
            date: Date(),
            scannedRoot: tree.scannedRoot,
            mode: mode,
            volumeName: Self.volumeName(for: root),
            totalSize: tree.root.sizeOnDisk,
            fileCount: Int(tree.root.fileCount),
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            appVersion: Self.appVersion
        )
        try? store.save(tree: tree, metadata: meta)
        lastStats = stats
        reloadRuns()
        selectedRunID = meta.id
        // The authoritative tree replaces the live preview; drop its scratch state.
        stash = nil
        liveChildren = []
        present(tree: tree)
        phase = .idle
    }

    // MARK: Compare / diff

    var isComparing = false
    var baselineRunID: UUID?
    var diff: TreeDiff?
    var isDiffLoading = false

    var canCompare: Bool { runs.count >= 2 }
    var baselineRun: RunMetadata? { runs.first { $0.id == baselineRunID } }

    func toggleCompare() {
        isComparing.toggle()
        if isComparing {
            if baselineRunID == nil { baselineRunID = defaultBaselineID() }
            recomputeDiff()
        } else {
            diff = nil
        }
    }

    func setBaseline(_ id: UUID) {
        baselineRunID = id
        recomputeDiff()
    }

    /// The next-older run relative to the selected one.
    private func defaultBaselineID() -> UUID? {
        guard let current = selectedRunID, let idx = runs.firstIndex(where: { $0.id == current }) else {
            return nil
        }
        return runs[(idx + 1)...].first?.id
    }

    /// Recomputes compare state when the selected run changes.
    private func refreshCompareForCurrentRun() {
        guard isComparing else { return }
        if baselineRunID == nil || baselineRunID == selectedRunID {
            baselineRunID = defaultBaselineID()
        }
        recomputeDiff()
    }

    private func recomputeDiff() {
        guard isComparing, let baselineRunID, let current = tree else { diff = nil; return }
        isDiffLoading = true
        diff = nil
        let store = self.store
        Task {
            let baseline = await Task.detached { try? store.loadTree(id: baselineRunID) }.value
            // Bail if anything we diffed against changed while the baseline loaded:
            // a different baseline, compare turned off, or — crucially — a new
            // current tree (selecting another run). Otherwise a stale diff keyed by
            // the old tree's node identities would overwrite the fresh one and tint
            // every segment gray. The superseding present() spawns its own recompute.
            guard isComparing, self.baselineRunID == baselineRunID,
                  self.tree?.root === current.root else { return }
            if let baseline {
                let computed = await Task.detached { DiffEngine.diff(baseline: baseline, current: current) }.value
                self.diff = computed
            }
            isDiffLoading = false
        }
    }

    // MARK: Helpers

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private static func volumeName(for url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }

    /// Display name for a scanned root, matching the scanner's own root naming so
    /// the live preview and the final tree share a breadcrumb label.
    private static func rootName(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == "/" { return "/" }
        let comp = (path as NSString).lastPathComponent
        return comp.isEmpty ? path : comp
    }
}
