import Foundation
import Observation

public enum AnkiFailure: Equatable, Sendable {
    /// Connection refused/reset: Anki isn't running, or AnkiConnect isn't installed.
    case ankiClosed
    case other
}

public enum ReviewPhase: Equatable, Sendable {
    /// Nothing has been asked of Anki yet.
    case idle
    case loading
    case front(CurrentCard)
    case back(CurrentCard)
    case submitting(CurrentCard)
    case allDone
    case failed(AnkiFailure)

    /// The one line the panel shows instead of a card; nil while a card is up.
    public var message: String? {
        switch self {
        case .allDone: "All done"
        case .failed(.ankiClosed): "Open Anki"
        case .failed(.other): "Anki error"
        case .idle, .loading, .front, .back, .submitting: nil
        }
    }
}

public enum ReviewKey: Sendable {
    case space, one, undo
}

/// State machine over Anki's GUI review flow (`guiDeckReview → guiCurrentCard →
/// guiStartCardTimer → guiShowAnswer → guiAnswerCard`). Anki stays the only
/// scheduler. `guiDeckReview` takes one deck, so "all decks" means walking the
/// top-level decks that have cards due, in order.
@MainActor
@Observable
public final class ReviewSession {
    public private(set) var phase: ReviewPhase = .idle
    /// Anki's media folder, fetched when a review starts. Nil just means
    /// images won't load; the card text still renders.
    public private(set) var mediaDir: String?
    /// The deck picked from the deck menu; nil means every deck. In memory
    /// only: a relaunch starts on all decks again.
    public private(set) var chosenDeck: String?

    private let client: any AnkiConnectClient
    private let stalePollInterval: Duration
    private let undoPollInterval: Duration
    private var remainingDecks: [String] = []
    private var isOpening = false
    private var isHandling = false
    private var restartPending = false
    private var isUndoing = false
    /// The deck whose cards are being reviewed now: the one `guiDeckReview`
    /// last entered.
    private var activeDeck: String?
    /// Cards this app answered in `activeDeck`, newest last. Anki's undo takes
    /// back its *latest* operation whatever it was, so this is cleared whenever
    /// something else may have happened since (another deck entered, a
    /// restart, Anki's card changed under us).
    private var undoable: [Int64] = []

    /// Re-reads of the current card allowed after an answer while Anki is
    /// still on the card just answered, before it is accepted as legitimately
    /// back (a learning card can be due again at once).
    private static let stalePolls = 5
    /// `guiUndo` only schedules Anki's undo, so the undone card can take a
    /// moment to reach the front of the queue.
    private static let undoPolls = 15

    public init(client: any AnkiConnectClient,
                stalePollInterval: Duration = .milliseconds(40),
                undoPollInterval: Duration = .milliseconds(100)) {
        self.client = client
        self.stalePollInterval = stalePollInterval
        self.undoPollInterval = undoPollInterval
    }

    /// The hover entry point. Starts a review from idle, "all done" or a
    /// failure; mid-card it only checks that Anki is still on the same card.
    public func open() async {
        guard !isOpening, !isUndoing else { return }
        isOpening = true
        defer { isOpening = false }
        switch phase {
        case .loading, .submitting: return
        case .idle, .allDone, .failed: await start()
        case .front(let card), .back(let card): await verify(shown: card)
        }
        await restartIfChoiceWasMadeMeanwhile()
    }

    /// Review only `deck` (a parent includes its subdecks), or every deck for
    /// nil. Restarts the session on it: Anki owns the queue, so nothing is
    /// lost. Chosen while a request is in flight, it is applied when that
    /// finishes. Choosing what is already chosen, with a card up, does nothing.
    public func choose(_ deck: String?) async {
        if deck == chosenDeck {
            switch phase {
            case .front, .back, .submitting, .loading: return
            case .idle, .allDone, .failed: break
            }
        }
        chosenDeck = deck
        if isOpening || isHandling || phase == .loading || isSubmitting {
            restartPending = true
            return
        }
        isOpening = true
        defer { isOpening = false }
        await start()
    }

    /// Anki's deck names, for the picker; nil when Anki can't be reached (the
    /// menu then doesn't open, and the panel's own line says why).
    public func availableDecks() async -> [String]? {
        try? await client.deckNames()
    }

    /// Space flips on the front and answers Good on the back; `1` answers
    /// Again on the back; ⌘Z (`.undo`) takes back the last answer from either
    /// side, or from "All done". Every other combination does nothing.
    public func handle(_ key: ReviewKey) async {
        isHandling = true
        switch (phase, key) {
        case (.front(let card), .space): await flip(card)
        case (.back, .space): await answer(.good)
        case (.back, .one): await answer(.again)
        case (_, .undo): await undo()
        default: break
        }
        isHandling = false
        await restartIfChoiceWasMadeMeanwhile()
    }

    private var isSubmitting: Bool {
        if case .submitting = phase { return true }
        return false
    }

    private func restartIfChoiceWasMadeMeanwhile() async {
        guard restartPending else { return }
        restartPending = false
        let wasOpening = isOpening
        isOpening = true
        defer { isOpening = wasOpening }
        await start()
    }

    // MARK: Flow

    private func start() async {
        phase = .loading
        remainingDecks = []
        undoable = []
        activeDeck = nil
        do {
            let names = try await client.deckNames()
            if let chosen = chosenDeck, names.contains(chosen) {
                // No due filter: an empty deck ends at "All done" by itself.
                remainingDecks = [chosen]
            } else {
                chosenDeck = nil  // never chosen, or deleted/renamed in Anki since
                let topLevel = names.filter { !$0.contains("::") }
                let due = Set(try await client.deckStats(decks: topLevel)
                    .filter { $0.dueTotal > 0 }.map(\.name))
                remainingDecks = topLevel.filter(due.contains)
            }
            // Only after Anki has answered once: with Anki frozen this must not
            // add a second timeout before the panel can say so.
            mediaDir = try? await client.mediaDirPath()
            await enterNextDeck()
        } catch {
            fail(error)
        }
    }

    /// Re-hover mid-card. Same card: nothing to do, the side stays as it was.
    /// A different card means the user reviewed in Anki itself meanwhile.
    private func verify(shown card: CurrentCard) async {
        do {
            let current = try await client.currentCard()
            guard current.cardId != card.cardId else { return }
            undoable = []  // Anki's latest operation is no longer ours
            try await client.startCardTimer()
            phase = .front(current)
        } catch let error as AnkiConnectError where error.isReviewInactive {
            await start()
        } catch AnkiConnectError.declined {
            await start()
        } catch {
            fail(error)
        }
    }

    private func flip(_ card: CurrentCard) async {
        do {
            try await client.showAnswer()
            phase = .back(card)
        } catch let error as AnkiConnectError where error.isReviewInactive {
            await start()
        } catch AnkiConnectError.declined {
            // Anki's reviewer isn't showing a question any more.
            await start()
        } catch {
            fail(error)
        }
    }

    private func answer(_ rating: Rating) async {
        guard case .back(let card) = phase else { return }
        // Set before the first await so a held key can't answer twice.
        phase = .submitting(card)
        do {
            // Anki may have moved on (reviewed in Anki itself, or restarted).
            // Grading then would grade a card the user never saw.
            let current = try await client.currentCard()
            guard current.cardId == card.cardId else {
                undoable = []
                try await client.startCardTimer()
                phase = .front(current)
                return
            }
            try await client.answerCurrentCard(ease: card.ease(for: rating))
            undoable.append(card.cardId)
            if try await showCurrentCard(notYet: card.cardId) { return }
            await enterNextDeck()
        } catch let error as AnkiConnectError where error.isReviewInactive {
            await enterNextDeck()
        } catch AnkiConnectError.declined {
            // Anki refused the grade: it is not on this card's answer side.
            await start()
        } catch {
            fail(error)
        }
    }

    /// Take back the last answer with Anki's own undo, and show that card on
    /// its front. Nothing to take back: nothing happens.
    ///
    /// `guiUndo` alone changes nothing on screen: Anki's reviewer refreshes
    /// after an operation only while Anki's window is focused. So the deck
    /// being reviewed is entered again (selecting the same deck keeps Anki's
    /// queue, with the undone card at its front) and the current card is
    /// polled until it is the undone one. The deck choice and the remaining
    /// decks are left alone: `undoable` only holds answers from `activeDeck`.
    private func undo() async {
        guard let undoneId = undoable.last, let deck = activeDeck else { return }
        switch phase {
        case .front(let card), .back(let card):
            // Set before the first await so a double press can't undo twice.
            phase = .submitting(card)
        case .allDone:
            break  // the flag below is what stops a second press
        case .idle, .loading, .submitting, .failed: return
        }
        isUndoing = true
        defer { isUndoing = false }
        do {
            try await client.undo()
            var card = try await reenterAndFetch(deck)
            var polls = 0
            while card?.cardId != undoneId, polls < Self.undoPolls {
                polls += 1
                try await Task.sleep(for: undoPollInterval)
                card = try await reenterAndFetch(deck)
            }
            guard let card, card.cardId == undoneId else {
                // Anki never showed it: whatever was undone, it wasn't what
                // we expected. Start over from Anki's real state.
                await start()
                return
            }
            undoable.removeLast()
            try await client.startCardTimer()
            phase = .front(card)
        } catch AnkiConnectError.declined {
            await start()
        } catch let error as AnkiConnectError where error.isReviewInactive {
            await start()
        } catch {
            fail(error)
        }
    }

    /// `guiDeckReview` on `deck`, then the card it shows; nil when no review
    /// is active (the deck has nothing to show).
    private func reenterAndFetch(_ deck: String) async throws -> CurrentCard? {
        try await client.startReview(deckName: deck)
        do {
            return try await client.currentCard()
        } catch let error as AnkiConnectError where error.isReviewInactive {
            return nil
        }
    }

    /// Enter decks until one has a card to show; none left means all done.
    private func enterNextDeck() async {
        while !remainingDecks.isEmpty {
            let deck = remainingDecks.removeFirst()
            do {
                try await client.startReview(deckName: deck)
                if deck != activeDeck { undoable = [] }
                activeDeck = deck
                if try await showCurrentCard() { return }
            } catch AnkiConnectError.declined {
                continue  // Anki wouldn't enter this deck (renamed or deleted)
            } catch {
                fail(error)
                return
            }
        }
        phase = .allDone
    }

    /// Show Anki's current card. False means the deck is drained, which is
    /// the normal end of a queue ("review is not currently active").
    ///
    /// `staleId` is the card just answered: Anki applies an answer in the
    /// background, so for a moment its reviewer can still be on that card.
    /// Wait a few beats for it to move on, then accept it (a learning card can
    /// legitimately be due again straight away).
    private func showCurrentCard(notYet staleId: Int64? = nil) async throws -> Bool {
        do {
            var card = try await client.currentCard()
            var polls = 0
            while card.cardId == staleId, polls < Self.stalePolls {
                polls += 1
                try await Task.sleep(for: stalePollInterval)
                card = try await client.currentCard()
            }
            try await client.startCardTimer()
            phase = .front(card)
            return true
        } catch let error as AnkiConnectError where error.isReviewInactive {
            return false
        } catch AnkiConnectError.declined {
            return false  // the reviewer closed between the two requests
        }
    }

    private func fail(_ error: any Error) {
        if case AnkiConnectError.unreachable = error {
            phase = .failed(.ankiClosed)
        } else {
            phase = .failed(.other)
        }
    }
}
