import Foundation

/// Turns Anki's `::`-separated deck path into text for the route row. Pure:
/// measuring which form fits is the app's job (it owns the font).
public enum DeckRoute {
    static let separator = " › "
    static let ellipsis = "…"

    /// The deck path's parts, trimmed, with empty ones dropped.
    public static func components(of deckName: String) -> [String] {
        deckName.components(separatedBy: "::")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Display strings from longest to shortest: the full path, then the root
    /// and the leaf around an ellipsis, then the leaf behind an ellipsis. The
    /// caller takes the first that fits.
    public static func candidates(for deckName: String) -> [String] {
        let parts = components(of: deckName)
        guard let first = parts.first, let last = parts.last else { return [] }
        var result = [parts.joined(separator: separator)]
        if parts.count >= 3 {
            result.append([first, ellipsis, last].joined(separator: separator))
        }
        if parts.count >= 2 {
            result.append([ellipsis, last].joined(separator: separator))
        }
        return result
    }
}
