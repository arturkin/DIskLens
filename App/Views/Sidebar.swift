import SwiftUI
import DiskLensCore

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedRunID) {
            Section("Scan") {
                Button { model.startScan(root: FileManager.default.homeDirectoryForCurrentUser) } label: {
                    Label("Home Folder", systemImage: "house")
                }
                Button(action: chooseFolder) {
                    Label("Choose Folder…", systemImage: "folder")
                }
                Button { model.startScan(root: URL(filePath: "/")) } label: {
                    Label("Whole Disk", systemImage: "internaldrive")
                }
                Button { model.startScan(root: URL(filePath: "/"), mode: .admin) } label: {
                    Label("Whole Disk (Admin)…", systemImage: "lock.shield")
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning)

            Section("History") {
                if model.runs.isEmpty {
                    Text("No scans yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(model.runs) { run in
                    RunRow(run: run).tag(run.id)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        .onChange(of: model.selectedRunID) { _, id in
            if let id { model.select(runID: id) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan"
        if panel.runModal() == .OK, let url = panel.url {
            model.startScan(root: url)
        }
    }
}

private struct RunRow: View {
    let run: RunMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: run.mode == .admin ? "lock.shield" : "person")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(displayRoot)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .font(.callout.weight(.medium))
            }
            HStack(spacing: 6) {
                Text(Format.bytes(run.totalSize))
                Text("·")
                Text(run.date, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var displayRoot: String {
        run.scannedRoot == "/" ? (run.volumeName ?? "Macintosh HD")
            : (run.scannedRoot as NSString).lastPathComponent
    }
}
