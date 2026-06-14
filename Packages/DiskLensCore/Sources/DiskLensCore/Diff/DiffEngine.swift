import Foundation

public enum DiffStatus: String, Sendable, Equatable {
    case added, removed, grew, shrank, unchanged
}

/// A single notable change between two scans (an added/removed item, or a file
/// that changed size).
public struct DiffChange: Sendable, Identifiable {
    public let id: Int
    public let path: [String]      // component names from the root
    public let name: String
    public let isDirectory: Bool
    public let status: DiffStatus
    public let baselineSize: Int64
    public let currentSize: Int64
    public var delta: Int64 { currentSize - baselineSize }
}

/// Result of comparing a baseline scan to a current scan.
public struct TreeDiff: Sendable {
    public let changes: [DiffChange]        // significant changes, |delta| desc
    public let totalDelta: Int64
    public let addedBytes: Int64
    public let removedBytes: Int64
    public let addedCount: Int
    public let removedCount: Int
    /// Net size delta per current-tree node, keyed by object identity (for chart tinting).
    public let deltaByCurrentNode: [ObjectIdentifier: Int64]
}

/// Compares two scan trees, matching children by name within each directory.
public enum DiffEngine {
    public static func diff(baseline: FileTree, current: FileTree) -> TreeDiff {
        var changes: [DiffChange] = []
        var nextID = 0
        var deltaMap: [ObjectIdentifier: Int64] = [:]
        var addedBytes: Int64 = 0, removedBytes: Int64 = 0
        var addedCount = 0, removedCount = 0

        func markAllAdded(_ node: FileNode) {
            deltaMap[ObjectIdentifier(node)] = node.sizeOnDisk
            for child in node.children { markAllAdded(child) }
        }

        func walk(_ b: FileNode?, _ c: FileNode?, path: [String]) {
            let bSize = b?.sizeOnDisk ?? 0
            let cSize = c?.sizeOnDisk ?? 0
            if let c { deltaMap[ObjectIdentifier(c)] = cSize - bSize }

            let representative = c ?? b
            let name = representative?.name ?? ""
            let isDir = representative?.isDirectory ?? false

            switch (b, c) {
            case (nil, .some(let c)):                       // wholesale added
                changes.append(DiffChange(
                    id: nextID, path: path, name: name, isDirectory: isDir,
                    status: .added, baselineSize: 0, currentSize: cSize))
                nextID += 1
                addedBytes += cSize
                addedCount += 1
                markAllAdded(c)

            case (.some, nil):                              // wholesale removed
                changes.append(DiffChange(
                    id: nextID, path: path, name: name, isDirectory: isDir,
                    status: .removed, baselineSize: bSize, currentSize: 0))
                nextID += 1
                removedBytes += bSize
                removedCount += 1

            case let (.some(b), .some(c)):
                if isDir {
                    let bKids = Dictionary(b.children.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                    let cKids = Dictionary(c.children.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                    var names: [String] = []
                    var seen = Set<String>()
                    for kid in c.children where seen.insert(kid.name).inserted { names.append(kid.name) }
                    for kid in b.children where seen.insert(kid.name).inserted { names.append(kid.name) }
                    for childName in names {
                        walk(bKids[childName], cKids[childName], path: path + [childName])
                    }
                } else if cSize != bSize {
                    changes.append(DiffChange(
                        id: nextID, path: path, name: name, isDirectory: false,
                        status: cSize > bSize ? .grew : .shrank,
                        baselineSize: bSize, currentSize: cSize))
                    nextID += 1
                }

            case (nil, nil):
                break
            }
        }

        walk(baseline.root, current.root, path: [])
        changes.sort { abs($0.delta) > abs($1.delta) }

        return TreeDiff(
            changes: changes,
            totalDelta: current.root.sizeOnDisk - baseline.root.sizeOnDisk,
            addedBytes: addedBytes, removedBytes: removedBytes,
            addedCount: addedCount, removedCount: removedCount,
            deltaByCurrentNode: deltaMap)
    }
}
