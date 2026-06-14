import SwiftUI
import DiskLensCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
        } detail: {
            ChartArea()
        }
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
        }
    }

    private var subtitle: String {
        guard let run = model.selectedRun else { return "" }
        return "\(Format.bytes(run.totalSize)) · \(Format.count(run.fileCount)) files"
    }
}
