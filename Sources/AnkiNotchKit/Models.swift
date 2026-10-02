import Foundation

/// The only two answers AnkiNotch gives.
public enum Rating: Sendable {
    case again, good
}

/// The card Anki's reviewer is on, as served by `guiCurrentCard`. Extra keys
/// in the payload (note type, intervals, fields) are ignored.
public struct CurrentCard: Decodable, Sendable, Equatable {
    public let cardId: Int64
    public let question: String
    public let answer: String
    public let css: String
    public let buttons: [Int]
    public let deckName: String

    public init(cardId: Int64, question: String, answer: String, css: String,
                buttons: [Int], deckName: String) {
        self.cardId = cardId
        self.question = question
        self.answer = answer
        self.css = css
        self.buttons = buttons
        self.deckName = deckName
    }

    /// Anki numbers a four-button card 1–4 (Again/Hard/Good/Easy) but a
    /// three-button one 1–3 (Again/Good/Easy), so Good is ease 3 only when
    /// there are four buttons. Decided from the button list, never fixed.
    public func ease(for rating: Rating) -> Int {
        switch rating {
        case .again: 1
        case .good: buttons.count >= 4 ? 3 : 2
        }
    }
}

/// Per-deck due counts from `getDeckStats`. A parent's counts include its subdecks.
public struct DeckStats: Decodable, Sendable, Equatable {
    public let deckId: Int64
    public let name: String
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int

    enum CodingKeys: String, CodingKey {
        case deckId = "deck_id"
        case name
        case newCount = "new_count"
        case learnCount = "learn_count"
        case reviewCount = "review_count"
    }

    public init(deckId: Int64, name: String, newCount: Int, learnCount: Int, reviewCount: Int) {
        self.deckId = deckId
        self.name = name
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
    }

    public var dueTotal: Int { newCount + learnCount + reviewCount }
}

public enum AnkiConnectError: Error, Equatable, Sendable {
    /// Connect refused/reset — Anki not running, AnkiConnect missing, or Anki died.
    case unreachable(String)
    /// AnkiConnect returned an error string in its response envelope.
    case api(String)
    /// The response was not the expected `{result, error}` envelope.
    case malformedResponse

    /// "Review is not currently active" is how Anki says the deck is drained.
    /// That is the normal end of a queue, not a failure.
    public var isReviewInactive: Bool {
        if case .api(let message) = self {
            return message.localizedCaseInsensitiveContains("review is not currently active")
        }
        return false
    }
}
