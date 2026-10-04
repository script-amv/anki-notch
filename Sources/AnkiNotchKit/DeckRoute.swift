import Foundation

/// Anki's `::`-separated deck path, split into its parts.
public enum DeckRoute {
    /// The deck path's parts, trimmed, with empty ones dropped.
    public static func components(of deckName: String) -> [String] {
        deckName.components(separatedBy: "::")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
