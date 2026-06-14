import Foundation

/// The selectable visualization styles. All read the same tree + focus.
enum VizKind: String, CaseIterable, Identifiable, Sendable {
    case sunburst
    case treemap
    case pie
    case list
    case icicle
    case bar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sunburst: "Sunburst"
        case .treemap:  "Treemap"
        case .pie:      "Pie"
        case .list:     "List"
        case .icicle:   "Icicle"
        case .bar:      "Bar"
        }
    }

    var symbol: String {
        switch self {
        case .sunburst: "circle.circle"
        case .treemap:  "square.grid.3x3.fill"
        case .pie:      "chart.pie.fill"
        case .list:     "list.bullet"
        case .icicle:   "chart.bar.doc.horizontal"
        case .bar:      "chart.bar.fill"
        }
    }
}
