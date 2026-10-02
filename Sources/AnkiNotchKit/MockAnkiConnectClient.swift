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
    private var staleReadsAfterAnswer = 0
    private var staleCard: CurrentCard?
    private var staleReads = 0

    /// Answered cards with the deck they came from, newest last (for undo).
    private var answeredCards: [(card: CurrentCard, deck: Int)] = []
    /// The deck `startReview` last entered, even if it had nothing to show.
    private var reviewerDeck: Int?
    /// After `undo()` Anki's reviewer keeps showing what it showed (nil: the
    /// "congratulations" screen) until `startReview` re-enters the deck.
    private var reviewerIsStale = false
    private var staleView: CurrentCard?
    private var pendingUndo: (card: CurrentCard, deck: Int, delay: Int)?
    private var undoDelayCalls = 0
    private var undoDeclined = false

    public private(set) var answered: [MockAnswer] = []
    public private(set) var undoCalls = 0
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

    /// After an answer, `currentCard()` keeps returning the answered card for
    /// this many reads — Anki applies an answer in the background, so right
    /// after `guiAnswerCard` its reviewer can still be on the old card.
    public func setStaleReadsAfterAnswer(_ reads: Int) { staleReadsAfterAnswer = reads }

    /// `guiUndo` only schedules the undo: it takes effect this many
    /// `startReview`/`currentCard` calls after it (0: at the next `startReview`).
    public func setUndoDelayCalls(_ calls: Int) { undoDelayCalls = calls }

    /// `guiUndo` answers `false`.
    public func setUndoDeclined(_ declined: Bool) { undoDeclined = declined }

    /// Anki is back on the question side (reviewer restarted, or flipped back).
    public func forgetAnswerShown() { answerShown = false }

    /// Take the current card as if it was answered in Anki's own window:
    /// no answer is recorded here.
    public func discardCurrentCard() { popCurrent() }

    /// `guiCurrentCard` raises this when no review is active.
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
        staleReads = 0
        reviewerIsStale = false
        let index = decks.firstIndex { $0.name == deckName }
        reviewerDeck = index
        tickUndo()
        activeDeck = index.flatMap { decks[$0].cards.isEmpty ? nil : $0 }
    }

    public func currentCard() async throws -> CurrentCard {
        try check()
        if reviewerIsStale {
            guard let staleView else { throw Self.inactive }
            return staleView
        }
        tickUndo()
        if staleReads > 0, let staleCard {
            staleReads -= 1
            return staleCard
        }
        guard let index = activeDeck, let card = decks[index].cards.first else {
            throw Self.inactive
        }
        return card
    }

    // The GUI actions below answer `false` — AnkiConnect's `declined` — when
    // the reviewer isn't where they need it, rather than raising an error.
    public func startCardTimer() async throws {
        try check()
        guard activeDeck != nil else { throw AnkiConnectError.declined("guiStartCardTimer") }
        timerStarts += 1
    }

    public func showAnswer() async throws {
        try check()
        guard activeDeck != nil else { throw AnkiConnectError.declined("guiShowAnswer") }
        answerShown = true
    }

    public func answerCurrentCard(ease: Int) async throws {
        try check()
        answerAttempts += 1
        guard let index = activeDeck, let card = decks[index].cards.first,
              answerShown else { throw AnkiConnectError.declined("guiAnswerCard") }
        answered.append(MockAnswer(cardId: card.cardId, ease: ease))
        answeredCards.append((card, index))
        popCurrent()
        if staleReadsAfterAnswer > 0 {
            staleCard = card
            staleReads = staleReadsAfterAnswer
        }
    }

    /// Anki's undo takes back the latest answer (nothing happens with none).
    /// Like the real add-on it is scheduled, not immediate, and the reviewer
    /// stays on what it showed until `startReview` re-enters the deck.
    public func undo() async throws {
        try check()
        undoCalls += 1
        if undoDeclined { throw AnkiConnectError.declined("guiUndo") }
        guard let last = answeredCards.popLast() else { return }
        answered.removeLast()
        staleView = activeDeck.flatMap { decks[$0].cards.first }
        reviewerIsStale = true
        pendingUndo = (last.card, last.deck, undoDelayCalls)
    }

    /// One step of the background undo: applied once its delay has run out.
    private func tickUndo() {
        guard let pending = pendingUndo else { return }
        if pending.delay > 0 {
            pendingUndo?.delay -= 1
            return
        }
        pendingUndo = nil
        decks[pending.deck].cards.insert(pending.card, at: 0)
        answerShown = false
        if reviewerDeck == pending.deck { activeDeck = pending.deck }
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
