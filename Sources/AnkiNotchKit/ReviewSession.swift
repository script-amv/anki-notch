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
    case space, one
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

    private let client: any AnkiConnectClient
    private let stalePollInterval: Duration
    private var remainingDecks: [String] = []
    private var isOpening = false

    /// Re-reads of the current card allowed after an answer while Anki is
    /// still on the card just answered, before it is accepted as legitimately
    /// back (a learning card can be due again at once).
    private static let stalePolls = 5

    public init(client: any AnkiConnectClient,
                stalePollInterval: Duration = .milliseconds(40)) {
        self.client = client
        self.stalePollInterval = stalePollInterval
    }

    /// The hover entry point. Starts a review from idle, "all done" or a
    /// failure; mid-card it only checks that Anki is still on the same card.
    public func open() async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        switch phase {
        case .loading, .submitting: return
        case .idle, .allDone, .failed: await start()
        case .front(let card), .back(let card): await verify(shown: card)
        }
    }

    /// Space flips on the front and answers Good on the back; `1` answers
    /// Again on the back. Every other combination does nothing.
    public func handle(_ key: ReviewKey) async {
        switch (phase, key) {
        case (.front(let card), .space): await flip(card)
        case (.back, .space): await answer(.good)
        case (.back, .one): await answer(.again)
        default: break
        }
    }

    // MARK: Flow

    private func start() async {
        phase = .loading
        remainingDecks = []
        do {
            let topLevel = try await client.deckNames().filter { !$0.contains("::") }
            let due = Set(try await client.deckStats(decks: topLevel)
                .filter { $0.dueTotal > 0 }.map(\.name))
            remainingDecks = topLevel.filter(due.contains)
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
                try await client.startCardTimer()
                phase = .front(current)
                return
            }
            try await client.answerCurrentCard(ease: card.ease(for: rating))
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

    /// Enter decks until one has a card to show; none left means all done.
    private func enterNextDeck() async {
        while !remainingDecks.isEmpty {
            let deck = remainingDecks.removeFirst()
            do {
                try await client.startReview(deckName: deck)
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
