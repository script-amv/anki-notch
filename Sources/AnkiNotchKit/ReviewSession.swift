import Foundation
import Observation
import os

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
    private let recoveryDelay: Duration
    /// One operation at a time. Every key press is its own unawaited task, and
    /// two flows interleaving at their `await`s corrupt each other's state: a
    /// card graded twice, a deck list one flow consumed under another ("All
    /// done" with cards left), a flip landing in the middle of Anki's answer.
    private var isBusy = false
    /// A key that arrived while a flip (or a re-check) was in flight: it waits
    /// for its turn, and a later one replaces it. A key that arrives while an
    /// answer, an undo or a (re)start is in flight is dropped instead, because
    /// the card it would act on has not been seen yet.
    private var waitingKey: ReviewKey?
    private var restartPending = false

    private static let log = Logger(subsystem: "com.ankinotch.app", category: "session")
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
    /// back (a learning card can be due again at once). Each read costs a
    /// round trip (about 50 ms), so this is roughly a second: Anki must be
    /// given time to finish applying the answer, because flipping its reviewer
    /// mid-answer would let the same card be graded again.
    private static let stalePolls = 12
    /// `guiUndo` only schedules Anki's undo, so the undone card can take a
    /// moment to reach the front of the queue.
    private static let undoPolls = 15

    public init(client: any AnkiConnectClient,
                stalePollInterval: Duration = .milliseconds(40),
                undoPollInterval: Duration = .milliseconds(100),
                recoveryDelay: Duration = .milliseconds(250)) {
        self.client = client
        self.stalePollInterval = stalePollInterval
        self.undoPollInterval = undoPollInterval
        self.recoveryDelay = recoveryDelay
    }

    /// The hover entry point. Starts a review from idle, "all done" or a
    /// failure; mid-card it only checks that Anki is still on the same card.
    /// While anything else is running it does nothing: that operation leaves
    /// Anki and the panel in step.
    public func open() async {
        guard !isBusy else { return }
        await run(.open)
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
        if isBusy || phase == .loading || isSubmitting {
            restartPending = true
            return
        }
        await run(.restart)
    }

    /// Anki's deck names, for the picker; nil when Anki can't be reached (the
    /// menu then doesn't open, and the panel's own line says why).
    public func availableDecks() async -> [String]? {
        try? await client.deckNames()
    }

    /// Space flips on the front and answers Good on the back; `1` answers
    /// Again on the back; ⌘Z (`.undo`) takes back the last answer from either
    /// side, or from "All done". Every other combination does nothing.
    ///
    /// Presses are handled one at a time, in order. One that arrives while a
    /// flip is in flight waits for it (flip, then Good: what a fast press
    /// means); one that arrives during an answer is dropped.
    public func handle(_ key: ReviewKey) async {
        if isBusy {
            switch phase {
            case .front, .back: waitingKey = key
            case .idle, .loading, .submitting, .allDone, .failed: break
            }
            return
        }
        await run(.key(key))
    }

    private var isSubmitting: Bool {
        if case .submitting = phase { return true }
        return false
    }

    // MARK: Serial runner

    private enum Operation {
        case open
        case restart
        case key(ReviewKey)
    }

    /// Runs `first`, then whatever was left waiting meanwhile: a deck choice
    /// (which makes a waiting key stale) before a key.
    private func run(_ first: Operation) async {
        isBusy = true
        var next: Operation? = first
        while let operation = next {
            await execute(operation)
            if restartPending {
                restartPending = false
                waitingKey = nil
                next = .restart
            } else if let key = waitingKey {
                waitingKey = nil
                next = .key(key)
            } else {
                next = nil
            }
        }
        isBusy = false
    }

    private func execute(_ operation: Operation) async {
        switch operation {
        case .open:
            switch phase {
            case .loading, .submitting: return
            case .idle, .allDone, .failed: await start()
            case .front(let card), .back(let card): await verify(shown: card)
            }
        case .restart:
            await start()
        case .key(let key):
            switch (phase, key) {
            case (.front(let card), .space): await flip(card)
            case (.back, .space): await answer(.good)
            case (.back, .one): await answer(.again)
            case (_, .undo): await undo()
            default: break
            }
        }
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
            try await startTimer()
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
            await recover(from: error)
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
                try await startTimer()
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
            await recover(from: error)
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
            try await startTimer()
            phase = .front(card)
        } catch AnkiConnectError.declined {
            await start()
        } catch let error as AnkiConnectError where error.isReviewInactive {
            await start()
        } catch {
            await recover(from: error)
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
            try await startTimer()
            phase = .front(card)
            return true
        } catch let error as AnkiConnectError where error.isReviewInactive {
            return false
        } catch AnkiConnectError.declined {
            return false  // the reviewer closed between the two requests
        }
    }

    /// `guiStartCardTimer` only feeds Anki's time statistics. It answers
    /// `false` while the reviewer is between two cards, and that must not be
    /// mistaken for a drained deck (which would end the session early), so a
    /// refusal is ignored. Real failures still propagate.
    private func startTimer() async throws {
        do {
            try await client.startCardTimer()
        } catch AnkiConnectError.declined {
            Self.log.debug("guiStartCardTimer declined; showing the card anyway")
        }
    }

    /// Anki is sometimes briefly out of step with us: it applies an answer in
    /// the background, and a request can land in the middle of that. Before an
    /// error screen, look at what Anki shows now and carry on from there; only
    /// an Anki that still fails is an error.
    private func recover(from error: any Error) async {
        // The failed request may have applied, or Anki may have moved on
        // independently. Its latest undo operation is no longer safely ours.
        undoable = []
        Self.log.error("Re-syncing after: \(String(describing: error), privacy: .public)")
        do {
            try await Task.sleep(for: recoveryDelay)
            let current = try await client.currentCard()
            try await startTimer()
            phase = .front(current)
        } catch let again as AnkiConnectError where again.isReviewInactive {
            await start()
        } catch AnkiConnectError.declined {
            await start()
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        Self.log.error("Showing the error screen: \(String(describing: error), privacy: .public)")
        if case AnkiConnectError.unreachable = error {
            phase = .failed(.ankiClosed)
        } else {
            phase = .failed(.other)
        }
    }
}
