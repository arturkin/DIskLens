import SwiftUI
import DiskLensCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrefKey.appearance) private var appearance = AppAppearance.dark.rawValue

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
        } detail: {
            ChartArea()
                .inspector(isPresented: $model.isComparing) {
                    ChangesInspector()
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                }
        }
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        .navigationTitle("DiskLens")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.vizKind) {
                    ForEach(VizKind.allCases) { kind in
                        Image(systemName: kind.symbol).tag(kind)
                            .help(kind.title)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.focus == nil)
            }
            ToolbarItemGroup(placement: .automatic) {
                if model.isComparing, model.canCompare {
                    Menu {
                        ForEach(model.runs.filter { $0.id != model.selectedRunID }) { run in
                            Button {
                                model.setBaseline(run.id)
                            } label: {
                                Label(baselineTitle(run), systemImage: run.id == model.baselineRunID ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Label("Baseline", systemImage: "calendar.badge.clock")
                    }
                    .help("Choose the run to compare against")
                }
                Button {
                    model.toggleCompare()
                } label: {
                    Label("Compare", systemImage: "arrow.left.arrow.right")
                }
                .help("Compare this scan to a previous one")
                .disabled(!model.canCompare)
                .symbolVariant(model.isComparing ? .fill : .none)
            }
        }
    }

    private func baselineTitle(_ run: RunMetadata) -> String {
        let name = run.scannedRoot == "/" ? (run.volumeName ?? "Disk")
            : (run.scannedRoot as NSString).lastPathComponent
        return "\(name) — \(run.date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var subtitle: String {
        guard let run = model.selectedRun else { return "" }
        return "\(Format.bytes(run.totalSize)) · \(Format.count(run.fileCount)) files"
    }
}
