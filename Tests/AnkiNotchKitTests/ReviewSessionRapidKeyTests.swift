import Testing
@testable import AnkiNotchKit

/// Pressing keys faster than Anki answers. Every key press is its own
/// unawaited task in the app (the key monitor), so the session must cope with
/// calls overlapping, and with Anki still applying the last answer in the
/// background — without double-grading, ending early or showing an error.
@MainActor @Suite struct ReviewSessionRapidKeyTests {
    private func make(cards count: Int, latency: Duration = .zero, lag: Duration = .zero,
                      pollInterval: Duration = .milliseconds(1))
        async -> (ReviewSession, MockAnkiConnectClient) {
        let mock = MockAnkiConnectClient(decks: [("A", (1...count).map { makeCard(Int64($0)) })])
        await mock.setLatency(latency)
        await mock.setAnswerLag(lag)
        return (ReviewSession(client: mock, stalePollInterval: pollInterval,
                              undoPollInterval: .milliseconds(1),
                              recoveryDelay: .milliseconds(1)), mock)
    }

    @Test func aFlipAndAnAnswerPressedTogetherBothApply() async {
        let (session, mock) = await make(cards: 3, latency: .milliseconds(5))
        await session.open()
        // The second press lands while the flip is still in flight: it is the
        // answer the user meant, not a second flip.
        async let first: Void = session.handle(.space)
        async let second: Void = session.handle(.space)
        _ = await (first, second)
        #expect(await mock.answered == [MockAnswer(cardId: 1, ease: 3)])
        #expect(session.phase == .front(makeCard(2)))
    }

    @Test func keysWhileAnAnswerIsInFlightAreDropped() async {
        let (session, mock) = await make(cards: 3, latency: .milliseconds(5))
        await session.open()
        await session.handle(.space)
        // The next card hasn't been seen yet: nothing may flip or grade it.
        async let a: Void = session.handle(.space)
        async let b: Void = session.handle(.space)
        async let c: Void = session.handle(.space)
        async let d: Void = session.handle(.space)
        _ = await (a, b, c, d)
        #expect(await mock.answered.count == 1)
        #expect(await mock.answerAttempts == 1)
        #expect(session.phase == .front(makeCard(2)))
    }

    @Test func rapidPressesNeverGradeACardTwiceOrEndTheSessionEarly() async {
        // Anki takes 120 ms to apply an answer; the session waits for it with
        // polls 10 ms apart (each call itself takes 4 ms).
        let (session, mock) = await make(cards: 40, latency: .milliseconds(4),
                                         lag: .milliseconds(120), pollInterval: .milliseconds(10))
        await session.open()
        var bad: [String] = []
        for _ in 0..<60 {
            Task { await session.handle(.space) }  // unawaited, like the key monitor
            try? await Task.sleep(for: .milliseconds(3))
            switch session.phase {
            case .allDone: bad.append("allDone")
            case .failed(let failure): bad.append("failed \(failure)")
            default: break
            }
        }
        try? await Task.sleep(for: .milliseconds(900))
        let ids = await mock.answered.map(\.cardId)
        #expect(Set(ids).count == ids.count, "a card was graded twice: \(ids)")
        #expect(!ids.isEmpty)
        #expect(bad.isEmpty, "\(bad)")
    }

    @Test func aTimerHiccupBetweenTwoCardsDoesNotEndTheSession() async {
        let (session, mock) = await make(cards: 3)
        await session.open()
        await session.handle(.space)
        // guiStartCardTimer answers false while Anki's reviewer is between
        // cards. That is not "the deck is drained".
        await mock.declineNextTimerStarts(1)
        await session.handle(.space)
        #expect(await mock.answered == [MockAnswer(cardId: 1, ease: 3)])
        #expect(session.phase == .front(makeCard(2)))
    }

    @Test func anUnexpectedErrorMidFlipIsRecoveredNotShown() async {
        let (session, mock) = await make(cards: 3)
        await session.open()
        await mock.failNextCalls(1, with: .api("Prediction/conversion token is stale."))
        await session.handle(.space)
        #expect(session.phase == .front(makeCard(1)), "should have re-synced, got \(session.phase)")
        await session.handle(.space)
        #expect(session.phase == .back(makeCard(1)))
    }

    @Test func anUnexpectedErrorMidAnswerIsRecoveredWithoutGradingTwice() async {
        let (session, mock) = await make(cards: 3)
        await session.open()
        await session.handle(.space)
        await mock.failNextCalls(1, with: .api("boom"))
        await session.handle(.space)
        #expect(!(session.phase.message != nil), "got \(session.phase)")
        #expect(await mock.answered.count <= 1)
    }

    @Test func aPersistentErrorMidFlipStillShowsTheErrorScreen() async {
        let (session, mock) = await make(cards: 3)
        await session.open()
        await mock.setFailure(.api("boom"))
        await session.handle(.space)
        #expect(session.phase == .failed(.other))
        #expect(session.phase.message == "Anki error")
    }

    @Test func anAnkiThatVanishesMidAnswerShowsOpenAnki() async {
        let (session, mock) = await make(cards: 3)
        await session.open()
        await session.handle(.space)
        await mock.setFailure(.unreachable("connection refused"))
        await session.handle(.space)
        #expect(session.phase == .failed(.ankiClosed))
        #expect(session.phase.message == "Open Anki")
    }
}
