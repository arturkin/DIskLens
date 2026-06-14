import SwiftUI
import DiskLensCore

/// Headless snapshot mode for development verification.
///
/// Launch with `--snapshot <dir>` to render the active run's charts to PNGs and
/// quit. Uses `ImageRenderer`, so it draws the real SwiftUI views with real data
/// and needs no Screen Recording permission.
enum SnapshotMode {
    static var requestedDirectory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(filePath: args[i + 1])
    }

    @MainActor
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log = ""

        let model = AppModel()
        model.bootstrap()
        let size = CGSize(width: 1000, height: 760)

        log += "focus=\(model.focus?.name ?? "nil") children=\(model.focus?.children.count ?? -1)\n"
        log += "probe=\(render(Text("probe").font(.largeTitle), size: CGSize(width: 200, height: 100), to: dir.appending(path: "_probe.png")))\n"

        if let focus = model.focus {
            for kind in VizKind.allCases {
                model.vizKind = kind
                let ok = render(
                    ChartSnapshotHost(model: model, focus: focus),
                    size: size,
                    to: dir.appending(path: "\(kind.rawValue).png")
                )
                log += "\(kind.rawValue)=\(ok)\n"
            }
        } else {
            log += "empty=\(render(EmptyMessage(), size: size, to: dir.appending(path: "empty.png")))\n"
        }

        // Compare snapshot: tint the most-recent run against the next same-root run.
        let store = RunStore()
        let runs = (try? store.loadIndex()) ?? []
        if let current = runs.first,
           let baseline = runs.dropFirst().first(where: { $0.scannedRoot == current.scannedRoot }),
           let curTree = try? store.loadTree(id: current.id),
           let baseTree = try? store.loadTree(id: baseline.id) {
            let diff = DiffEngine.diff(baseline: baseTree, current: curTree)
            let tint = DeltaTint.make(diff.deltaByCurrentNode)
            log += "compare: \(diff.changes.count) changes, net \(diff.totalDelta) bytes, +\(diff.addedCount)/-\(diff.removedCount)\n"
            log += "compare=\(render(SunburstView(focus: curTree.root, hovered: nil, colorOverride: tint, onHover: { _ in }, onSelect: { _ in }, onBack: {}), size: size, to: dir.appending(path: "compare.png")))\n"
        }

        try? log.write(to: dir.appending(path: "log.txt"), atomically: true, encoding: .utf8)
        NSApplication.shared.terminate(nil)
    }

    @MainActor
    @discardableResult
    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) -> String {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2
        guard let image = renderer.nsImage else { return "nil-nsImage" }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return "nil-png" }
        do { try png.write(to: url); return "ok(\(png.count))" }
        catch { return "write-error \(error)" }
    }
}

/// Renders just the active chart for the given focus (no chrome).
private struct ChartSnapshotHost: View {
    let model: AppModel
    let focus: FileNode

    var body: some View {
        ChartContent(focus: focus)
            .environment(model)
            .padding(16)
    }
}

private struct EmptyMessage: View {
    var body: some View {
        Text("No run loaded").font(.title).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
