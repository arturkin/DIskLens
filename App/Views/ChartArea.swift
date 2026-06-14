import SwiftUI
import DiskLensCore

/// The detail pane: breadcrumb, the active chart, a hovered/selection status
/// bar, and scan progress / empty states.
struct ChartArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // Slim, non-blocking strip: the chart below stays fully interactive
            // while a scan runs (you keep browsing the previous run until the new
            // one swaps in on completion).
            if model.isScanning {
                ScanProgressBar()
                Divider()
            }
            ZStack {
                if model.focus != nil {
                    content
                } else if !model.isScanning {
                    EmptyStateView()
                }
                // Before the first subtree lands the live chart is empty — show a
                // spinner so the main view reads as "working", not stalled.
                if model.isScanning, model.focus?.children.isEmpty ?? true {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Scanning…").foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                if model.isLoadingRun {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Loading scan…").foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                if case .failed(let message) = model.phase {
                    ErrorOverlay(message: message)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .confirmationDialog(
            "Move \(model.trashCandidates.count) item\(model.trashCandidates.count == 1 ? "" : "s") to Trash?",
            isPresented: $model.isConfirmingTrash, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { model.confirmTrash() }
            Button("Cancel", role: .cancel) { model.trashCandidates = [] }
        } message: {
            let total = model.trashCandidates.reduce(Int64(0)) { $0 + $1.sizeOnDisk }
            Text("\(Format.bytes(total)) will be moved to the Trash. You can restore items from the Trash.")
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let stats = model.lastStats, stats.permissionDenied > 50 {
                FDABanner(count: stats.permissionDenied)
                Divider()
            }
            if model.isComparing {
                CompareSummaryBar()
                Divider()
            }
            BreadcrumbBar()
            if model.showsVolumeUsage {
                Divider()
                VolumeUsageBar()
            }
            Divider()
            if let focus = model.focus {
                ChartContent(focus: focus, renderNode: model.displayFocus)
                    .padding(16)
            }
            if !model.bag.isEmpty {
                Divider()
                BagBar()
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
    /// The real focus node — drives the zoom transition identity and navigation.
    let focus: FileNode
    /// The node actually drawn. Defaults to `focus`; the detail pane passes the
    /// free-space-decorated root here so the chart shows the whole volume.
    var renderNode: FileNode?

    private var node: FileNode { renderNode ?? focus }

    /// Delta tint closure when comparing, else nil (palette coloring).
    private var tint: ((FileNode?) -> Color)? {
        guard model.isComparing, let deltas = model.diff?.deltaByCurrentNode else { return nil }
        return DeltaTint.make(deltas)
    }

    var body: some View {
        // Re-identifying the chart on focus change lets the transition animate the
        // zoom in/out. Navigation methods wrap the focus change in `withAnimation`;
        // live-scan rebuilds don't, so they swap instantly (no flashing mid-scan).
        // Keyed on the *real* focus so swapping in the decorated root (same focus)
        // doesn't retrigger the zoom animation.
        chart
            .id(ObjectIdentifier(focus))
            .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    @ViewBuilder
    private var chart: some View {
        switch model.vizKind {
        case .sunburst:
            SunburstView(
                focus: node, hovered: model.hovered, colorOverride: tint,
                onHover: { model.hovered = $0 },
                onSelect: { model.drill(into: $0) },
                onBack: { model.goUp() }
            )
            .contextMenu { ChartNodeMenu(node: model.hovered) }
        case .pie:
            SunburstView(
                focus: node, hovered: model.hovered, maxDepth: 1, colorOverride: tint,
                onHover: { model.hovered = $0 },
                onSelect: { model.drill(into: $0) },
                onBack: { model.goUp() }
            )
            .contextMenu { ChartNodeMenu(node: model.hovered) }
        case .treemap:
            TreemapView(
                focus: node, hovered: model.hovered, colorOverride: tint,
                onHover: { model.hovered = $0 },
                onSelect: { model.drill(into: $0) }
            )
            .contextMenu { ChartNodeMenu(node: model.hovered) }
        case .icicle:
            IcicleView(
                focus: node, hovered: model.hovered, colorOverride: tint,
                onHover: { model.hovered = $0 },
                onSelect: { model.drill(into: $0) }
            )
            .contextMenu { ChartNodeMenu(node: model.hovered) }
        case .list:
            ListTableView(focus: node)
        case .bar:
            BarView(
                focus: node,
                onHover: { model.hovered = $0 },
                onSelect: { model.drill(into: $0) }
            )
            .contextMenu { ChartNodeMenu(node: model.hovered) }
        }
    }
}

// MARK: - Breadcrumb

private struct BreadcrumbBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.left")
                    .fontWeight(.semibold)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!model.canGoUp)
            .help("Back to enclosing folder (⌘[)")
            .keyboardShortcut("[", modifiers: .command)

            Divider().frame(height: 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.focusPath.enumerated()), id: \.offset) { index, node in
                        let isLast = index == model.focusPath.count - 1
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
                                .fontWeight(isLast ? .semibold : .regular)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isLast ? Color.primary : Color.accentColor)
                        .disabled(isLast)   // clicking the current folder is a no-op
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Volume usage header

/// A slim "Used · Free · Total" strip with a proportional bar, shown at the
/// volume root. Mirrors Disk Utility's capacity readout.
private struct VolumeUsageBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let usage = model.volumeUsage, let root = model.root {
            let scanned = max(0, root.sizeOnDisk)
            let capacity = max(usage.capacity, 1)
            let free = min(max(0, usage.free), usage.capacity)
            let other = max(0, usage.capacity - free - scanned)

            VStack(spacing: 5) {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        segment(scanned, of: capacity, width: geo.size.width, color: .accentColor)
                        segment(other, of: capacity, width: geo.size.width, color: VolumeSwatch.other)
                        segment(free, of: capacity, width: geo.size.width, color: VolumeSwatch.free)
                    }
                }
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                HStack(spacing: 14) {
                    legend(.accentColor, "Used", scanned)
                    if other > 0 { legend(VolumeSwatch.other, "Other", other) }
                    legend(VolumeSwatch.free, "Free", free)
                    Spacer()
                    Text("\(Format.bytes(usage.capacity)) total")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private func segment(_ value: Int64, of total: Int64, width: CGFloat, color: Color) -> some View {
        color.frame(width: max(0, width * CGFloat(value) / CGFloat(total)))
    }

    private func legend(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).foregroundStyle(.secondary)
            Text(Format.bytes(bytes)).fontWeight(.medium)
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if let node = model.hovered {
                Image(systemName: NodeIcon.symbol(for: node))
                    .foregroundStyle(.secondary)
                Text(node.name).fontWeight(.medium).lineLimit(1)
                Text(Format.bytes(node.sizeOnDisk)).foregroundStyle(.secondary)
                if let focus = model.displayFocus, focus.sizeOnDisk > 0 {
                    Text(Format.percent(Double(node.sizeOnDisk) / Double(focus.sizeOnDisk)))
                        .foregroundStyle(.tertiary)
                }
            } else if let focus = model.displayFocus {
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

/// Slim, non-blocking progress strip shown at the top of the detail pane while a
/// scan runs. Leaves the chart underneath fully usable.
private struct ScanProgressBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            if case .scanning(let p) = model.phase {
                Text("Scanning… \(Format.count(p.filesScanned)) files · \(Format.bytes(p.bytesScanned))")
                    .font(.callout).fontWeight(.medium)
                    .fixedSize()
                Text(p.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Authenticating…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.canCancelScan {
                Button("Cancel", role: .cancel) { model.cancelScan() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
