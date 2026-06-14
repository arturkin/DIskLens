import SwiftUI

@main
struct DiskLensApp: App {
    @State private var model = AppModel()

    init() {
        Preferences.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task {
                    if let dir = SnapshotMode.requestedDirectory {
                        SnapshotMode.run(into: dir)
                    } else {
                        model.bootstrap()
                    }
                }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Scan of Home Folder") {
                    model.startScan(root: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("n")
                .disabled(model.isScanning)

                Button("Rescan") {
                    model.rescanCurrent()
                }
                .keyboardShortcut("r")
                .disabled(!model.canRescan)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
