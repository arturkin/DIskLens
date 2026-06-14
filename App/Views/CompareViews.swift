import SwiftUI
import DiskLensCore

/// Delta-based tint for compare mode: green = grew/added, red = shrank/removed,
/// gray = unchanged.
enum DeltaTint {
    static func make(_ deltas: [ObjectIdentifier: Int64]) -> (FileNode?) -> Color {
        { node in
            guard let node, let d = deltas[ObjectIdentifier(node)], d != 0 else {
                return Color(white: 0.46)
            }
            return d > 0
                ? Color(hue: 0.34, saturation: 0.72, brightness: 0.80)
                : Color(hue: 0.00, saturation: 0.68, brightness: 0.86)
        }
    }
}

/// Summary line shown above the chart in compare mode.
struct CompareSummaryBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            if model.isDiffLoading {
                ProgressView().controlSize(.small)
                Text("Comparing…").foregroundStyle(.secondary)
            } else if let diff = model.diff {
                netLabel(diff.totalDelta)
                badge("\(diff.addedCount) added", color: .green, value: diff.addedBytes, sign: "+")
                badge("\(diff.removedCount) removed", color: .red, value: diff.removedBytes, sign: "−")
                if let baseline = model.baselineRun {
                    Spacer()
                    Text("vs \(baselineLabel(baseline)) · \(baseline.date.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Pick a baseline to compare").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func netLabel(_ delta: Int64) -> some View {
        let up = delta >= 0
        return Label {
            Text("\(up ? "+" : "−")\(Format.bytes(abs(delta))) net").fontWeight(.semibold)
        } icon: {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
        }
        .foregroundStyle(up ? .green : .red)
    }

    private func badge(_ text: String, color: Color, value: Int64, sign: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(text) · \(sign)\(Format.bytes(value))").foregroundStyle(.secondary)
        }
    }

    private func baselineLabel(_ run: RunMetadata) -> String {
        run.scannedRoot == "/" ? (run.volumeName ?? "disk") : (run.scannedRoot as NSString).lastPathComponent
    }
}

/// Trailing inspector listing the notable changes, largest delta first.
struct ChangesInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let diff = model.diff, !diff.changes.isEmpty {
                Table(diff.changes) {
                    TableColumn("") { change in
                        Image(systemName: icon(change.status))
                            .foregroundStyle(color(change.status))
                            .help(change.status.rawValue.capitalized)
                    }
                    .width(20)
                    TableColumn("Item") { change in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(change.name).lineLimit(1).truncationMode(.middle)
                            if change.path.count > 1 {
                                Text(change.path.dropLast().joined(separator: "/"))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                    TableColumn("Change") { change in
                        Text("\(change.delta >= 0 ? "+" : "−")\(Format.bytes(abs(change.delta)))")
                            .foregroundStyle(change.delta >= 0 ? .green : .red)
                            .monospacedDigit()
                    }
                    .width(90)
                }
            } else if model.isDiffLoading {
                ProgressView("Comparing…")
            } else {
                ContentUnavailableView("No changes", systemImage: "equal.circle",
                                       description: Text("This scan matches the baseline."))
            }
        }
        .navigationTitle("Changes")
    }

    private func icon(_ status: DiffStatus) -> String {
        switch status {
        case .added:   "plus.circle.fill"
        case .removed: "minus.circle.fill"
        case .grew:    "arrow.up.circle.fill"
        case .shrank:  "arrow.down.circle.fill"
        case .unchanged: "equal.circle"
        }
    }
    private func color(_ status: DiffStatus) -> Color {
        switch status {
        case .added, .grew: .green
        case .removed, .shrank: .red
        case .unchanged: .secondary
        }
    }
}
