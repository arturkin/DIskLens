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
                Button("Scan Home Folder") {
                    model.startScan(root: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("r")
                .disabled(model.isScanning)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
