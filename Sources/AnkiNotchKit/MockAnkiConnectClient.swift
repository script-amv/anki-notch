import Foundation

/// One answer the mock received.
public struct MockAnswer: Equatable, Sendable {
    public let cardId: Int64
    public let ease: Int
}

/// In-memory AnkiConnect stand-in for tests and Anki-free UI work: per-deck
/// card queues behind the same GUI review flow the live client drives.
public actor MockAnkiConnectClient: AnkiConnectClient {
    private var decks: [(name: String, cards: [CurrentCard])]
    private var activeDeck: Int?
    private var answerShown = false
    private var failure: AnkiConnectError?

    public private(set) var answered: [MockAnswer] = []
    public private(set) var enteredDecks: [String] = []
    public private(set) var timerStarts = 0
    /// Every `answerCurrentCard` call that reached the client, including ones
    /// the mock then rejected: a duplicate answer shows up here even though
    /// Anki would refuse it.
    public private(set) var answerAttempts = 0

    public init(decks: [(name: String, cards: [CurrentCard])]) {
        self.decks = decks
    }

    /// Make every following call throw `error` (nil restores normal service).
    public func setFailure(_ error: AnkiConnectError?) { failure = error }

    /// Take the current card as if it was answered in Anki's own window:
    /// no answer is recorded here.
    public func discardCurrentCard() { popCurrent() }

    private static let inactive = AnkiConnectError.api("Gui review is not currently active.")

    private func check() throws {
        if let failure { throw failure }
    }

    private func popCurrent() {
        guard let index = activeDeck, !decks[index].cards.isEmpty else { return }
        decks[index].cards.removeFirst()
        answerShown = false
        if decks[index].cards.isEmpty { activeDeck = nil }
    }

    public func deckNames() async throws -> [String] {
        try check()
        return decks.map(\.name)
    }

    public func deckStats(decks names: [String]) async throws -> [DeckStats] {
        try check()
        return decks.enumerated().filter { names.contains($0.element.name) }.map { index, deck in
            DeckStats(deckId: Int64(index), name: deck.name, newCount: 0, learnCount: 0,
                      reviewCount: deck.cards.count)
        }
    }

    public func startReview(deckName: String) async throws {
        try check()
        enteredDecks.append(deckName)
        answerShown = false
        let index = decks.firstIndex { $0.name == deckName }
        activeDeck = index.flatMap { decks[$0].cards.isEmpty ? nil : $0 }
    }

    public func currentCard() async throws -> CurrentCard {
        try check()
        guard let index = activeDeck, let card = decks[index].cards.first else {
            throw Self.inactive
        }
        return card
    }

    public func startCardTimer() async throws {
        try check()
        guard activeDeck != nil else { throw Self.inactive }
        timerStarts += 1
    }

    public func showAnswer() async throws {
        try check()
        guard activeDeck != nil else { throw Self.inactive }
        answerShown = true
    }

    public func answerCurrentCard(ease: Int) async throws {
        try check()
        answerAttempts += 1
        guard let index = activeDeck, let card = decks[index].cards.first else {
            throw Self.inactive
        }
        guard answerShown else { throw AnkiConnectError.api("Not in answer state") }
        answered.append(MockAnswer(cardId: card.cardId, ease: ease))
        popCurrent()
    }

    public func mediaDirPath() async throws -> String {
        try check()
        return "/tmp/ankinotch-media"
    }

    /// Two cards for UI work: one four-button, one three-button.
    public static let sampleCards: [CurrentCard] = [
        CurrentCard(cardId: 1, question: "<b>What is 2+2?</b>",
                    answer: "<b>What is 2+2?</b><hr id=answer>4",
                    css: ".card { font-family: arial; font-size: 20px; text-align: center; }",
                    buttons: [1, 2, 3, 4], deckName: "Sample"),
        CurrentCard(cardId: 2, question: "Capital of France?",
                    answer: "Capital of France?<hr id=answer>Paris",
                    css: ".card { font-family: arial; font-size: 20px; text-align: center; }",
                    buttons: [1, 2, 3], deckName: "Sample"),
    ]
}
