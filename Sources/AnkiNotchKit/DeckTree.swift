import Foundation

/// One deck in the picker: `path` is Anki's full `::` name (what
/// `guiDeckReview` takes), `name` just its last component.
public struct DeckNode: Equatable, Sendable {
    public let name: String
    public let path: String
    public let children: [DeckNode]
}

/// Turns Anki's flat deck list into the nested tree the picker menu shows.
/// Pure: the menu itself is the app's job.
public enum DeckTree {
    /// Roots and every level below them sorted by name (case-insensitive,
    /// numbers in natural order). A subdeck whose parents aren't listed gets
    /// the parents made up, so every node is reachable.
    public static func build(from names: [String]) -> [DeckNode] {
        var children: [String: Set<String>] = [:]  // parent path ("" = root) -> child paths
        for name in names {
            let parts = DeckRoute.components(of: name)
            for depth in parts.indices {
                let path = parts[...depth].joined(separator: "::")
                let parent = parts[..<depth].joined(separator: "::")
                children[parent, default: []].insert(path)
            }
        }
        func nodes(under parent: String) -> [DeckNode] {
            (children[parent] ?? [])
                .map { path in
                    DeckNode(name: path.components(separatedBy: "::").last ?? path,
                             path: path, children: nodes(under: path))
                }
                .sorted { $0.name.compare($1.name, options: [.caseInsensitive, .numeric]) == .orderedAscending }
        }
        return nodes(under: "")
    }
}
