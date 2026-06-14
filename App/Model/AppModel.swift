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
