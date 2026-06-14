import SwiftUI
import DiskLensCore

/// Placeholder shell — replaced with the real sidebar/chart layout in M3.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("DiskLens")
                .font(.largeTitle.bold())
            Text("Disk visualizer & cleaner")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

#Preview {
    ContentView()
}
