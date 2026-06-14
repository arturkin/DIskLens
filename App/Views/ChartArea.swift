import SwiftUI
import DiskLensCore

/// The detail pane: breadcrumb, the active chart, a hovered/selection status
/// bar, and scan progress / empty states.
struct ChartArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.focus != nil {
                content
            } else {
                EmptyStateView()
            }
            if model.isScanning {
                ScanProgressOverlay()
            }
            if case .failed(let message) = model.phase {
                ErrorOverlay(message: message)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            BreadcrumbBar()
            Divider()
            if let focus = model.focus {
                ChartContent(focus: focus)
                    .padding(16)
            }
            Divider()
            StatusBar()
        }
    }
}

/// Renders the active visualization for a focus node. Shared by the detail pane
/// and the headless snapshot mode.
struct ChartContent: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode

    var body: some View {
        switch model.vizKind {
        case .sunburst:
            SunburstView(
                focus: focus,
                hovered: model.hovered,
                onHover: { model.hovered = $0 },
                onSelect: { model.drill(into: $0) },
                onBack: { model.goUp() }
            )
        default:
            ContentUnavailableView(
                "\(model.vizKind.title) view",
                systemImage: model.vizKind.symbol,
                description: Text("Coming in the next milestone.")
            )
        }
    }
}

// MARK: - Breadcrumb

private struct BreadcrumbBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.focusPath.enumerated()), id: \.offset) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        model.focus(toDepth: index)
                    } label: {
                        Text(node.name)
                            .lineLimit(1)
                            .fontWeight(index == model.focusPath.count - 1 ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == model.focusPath.count - 1 ? Color.primary : Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if let node = model.hovered {
                Image(systemName: icon(for: node))
                    .foregroundStyle(.secondary)
                Text(node.name).fontWeight(.medium).lineLimit(1)
                Text(Format.bytes(node.sizeOnDisk)).foregroundStyle(.secondary)
                if let focus = model.focus, focus.sizeOnDisk > 0 {
                    Text(Format.percent(Double(node.sizeOnDisk) / Double(focus.sizeOnDisk)))
                        .foregroundStyle(.tertiary)
                }
            } else if let focus = model.focus {
                Text(focus.name).fontWeight(.medium).lineLimit(1)
                Text(Format.bytes(focus.sizeOnDisk)).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("\(Format.count(Int(focus.fileCount))) files").foregroundStyle(.secondary)
            }
            Spacer()
            if let stats = model.lastStats, stats.permissionDenied > 0 {
                Label("\(stats.permissionDenied) unreadable", systemImage: "lock")
                    .foregroundStyle(.orange)
                    .help("Some folders couldn't be read. Try an admin scan or grant Full Disk Access.")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 30)
    }

    private func icon(for node: FileNode) -> String {
        if node.flags.contains(.package) { return "shippingbox" }
        if node.flags.contains(.symlink) { return "arrow.up.right" }
        if node.flags.contains(.aggregatedSmallFiles) { return "ellipsis.circle" }
        return node.isDirectory ? "folder" : "doc"
    }
}

// MARK: - Overlays / empty states

private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("No scan loaded", systemImage: "internaldrive")
        } description: {
            Text("Scan your home folder or a volume to see where space is going.")
        } actions: {
            Button("Scan Home Folder") {
                model.startScan(root: FileManager.default.homeDirectoryForCurrentUser)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct ScanProgressOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            if case .scanning(let p) = model.phase {
                Text("\(Format.count(p.filesScanned)) files · \(Format.bytes(p.bytesScanned))")
                    .font(.headline)
                Text(p.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            Button("Cancel", role: .cancel) { model.cancelScan() }
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
    }
}

private struct ErrorOverlay: View {
    let message: String
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Scan failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Dismiss") { model.phase = .idle }
        }
    }
}
