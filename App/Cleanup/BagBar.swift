import SwiftUI
import DiskLensCore

/// Bottom bar showing the collection bag: count, reclaimable total, and batch
/// actions. Appears only when the bag is non-empty.
struct BagBar: View {
    @Environment(AppModel.self) private var model
    @State private var showingItems = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bag.fill").foregroundStyle(.tint)
            Text("\(model.bag.count) collected").fontWeight(.semibold)
            Text(Format.bytes(model.bagTotalSize)).foregroundStyle(.secondary)

            Button("Show") { showingItems.toggle() }
                .buttonStyle(.link)
                .popover(isPresented: $showingItems, arrowEdge: .top) { itemList }

            Spacer()

            Button("Empty", role: .cancel) { model.clearBag() }
            Button(role: .destructive) { model.requestTrashBag() } label: {
                Label("Move \(model.bag.count) to Trash", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Collection").font(.headline).padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.bag) { item in
                        HStack {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Format.bytes(item.size)).foregroundStyle(.secondary).monospacedDigit()
                            Button {
                                model.toggleCollect(item.node)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .frame(width: 360, height: 240)
        }
    }
}
