import Testing
@testable import AnkiNotchKit

@MainActor @Suite struct ReviewSessionTests {
    private typealias Decks = [(name: String, cards: [CurrentCard])]

    private func make(_ decks: Decks) -> (ReviewSession, MockAnkiConnectClient) {
        let mock = MockAnkiConnectClient(decks: decks)
        return (ReviewSession(client: mock), mock)
    }

    @Test func firstOpenEntersFirstDeckWithDueCardsAndShowsFront() async {
        let c1 = makeCard(1, deck: "日本語 Core")
        let (session, mock) = make([
            ("Empty", []),
            ("日本語 Core", [c1, makeCard(2, deck: "日本語 Core")]),
            ("日本語 Core::Sub", [makeCard(3, deck: "日本語 Core::Sub")]),
        ])
        await session.open()
        #expect(session.phase == .front(c1))
        #expect(await mock.enteredDecks == ["日本語 Core"])
        #expect(await mock.timerStarts == 1)
        #expect(session.mediaDir == "/tmp/ankinotch-media")
    }

    @Test func spaceFlipsThenAnswersGood() async {
        let (c1, c2) = (makeCard(1), makeCard(2))
        let (session, mock) = make([("A", [c1, c2])])
        await session.open()
        await session.handle(.space)
        #expect(session.phase == .back(c1))
        await session.handle(.space)
        #expect(session.phase == .front(c2))
        #expect(await mock.answered == [MockAnswer(cardId: 1, ease: 3)])
    }

    @Test func oneOnBackAnswersAgain() async {
        let (session, mock) = make([("A", [makeCard(1), makeCard(2)])])
        await session.open()
        await session.handle(.space)
        await session.handle(.one)
        #expect(await mock.answered == [MockAnswer(cardId: 1, ease: 1)])
    }

    @Test func threeButtonCardGoodIsEase2() async {
        let (session, mock) = make([("A", [makeCard(1, buttons: [1, 2, 3]), makeCard(2)])])
        await session.open()
        await session.handle(.space)
        await session.handle(.space)
        #expect(await mock.answered == [MockAnswer(cardId: 1, ease: 2)])
    }

    @Test func oneOnFrontDoesNothing() async {
        let c1 = makeCard(1)
        let (session, mock) = make([("A", [c1, makeCard(2)])])
        await session.open()
        await session.handle(.one)
        #expect(session.phase == .front(c1))
        #expect(await mock.answered.isEmpty)
    }

    @Test func drainedDeckAdvancesThenAllDone() async {
        let c2 = makeCard(2, deck: "B")
        let (session, mock) = make([("A", [makeCard(1, deck: "A")]), ("B", [c2])])
        await session.open()
        await session.handle(.space)
        await session.handle(.space)
        #expect(session.phase == .front(c2))
        #expect(await mock.enteredDecks == ["A", "B"])
        await session.handle(.space)
        await session.handle(.space)
        #expect(session.phase == .allDone)
        #expect(session.phase.message == "All done")
    }

    @Test func nothingDueAnywhereIsAllDoneOnFirstOpen() async {
        let (session, mock) = make([("A", [])])
        await session.open()
        #expect(session.phase == .allDone)
        #expect(await mock.enteredDecks.isEmpty)
    }

    @Test func reopenMidCardKeepsCardAndSide() async {
        let c1 = makeCard(1)
        let (session, mock) = make([("A", [c1, makeCard(2)])])
        await session.open()
        await session.handle(.space)
        await session.open()
        #expect(session.phase == .back(c1))
        #expect(await mock.enteredDecks.count == 1)
    }

    @Test func reopenAfterCardWasReviewedInAnkiShowsNewFront() async {
        let (c1, c2) = (makeCard(1), makeCard(2))
        let (session, mock) = make([("A", [c1, c2])])
        await session.open()
        #expect(session.phase == .front(c1))
        await mock.discardCurrentCard()
        await session.open()
        #expect(session.phase == .front(c2))
    }

    @Test func heldKeyAnswersOnlyOnce() async {
        let c2 = makeCard(2)
        let (session, mock) = make([("A", [makeCard(1), c2])])
        await session.open()
        await session.handle(.space)
        async let first: Void = session.handle(.space)
        async let second: Void = session.handle(.space)
        _ = await (first, second)
        #expect(await mock.answered.count == 1)
        // The second press must be dropped, not sent to Anki and rejected.
        #expect(await mock.answerAttempts == 1)
        #expect(session.phase == .front(c2))
    }

    @Test func unreachableAnkiThenRecovery() async {
        let c1 = makeCard(1)
        let (session, mock) = make([("A", [c1])])
        await mock.setFailure(.unreachable("x"))
        await session.open()
        #expect(session.phase == .failed(.ankiClosed))
        #expect(session.phase.message == "Open Anki")
        await mock.setFailure(nil)
        await session.open()
        #expect(session.phase == .front(c1))
    }

    @Test func ankiClosingMidCardRestartsOnNextOpen() async {
        let c1 = makeCard(1)
        let (session, mock) = make([("A", [c1])])
        await session.open()
        #expect(session.phase == .front(c1))
        await mock.setFailure(.unreachable("x"))
        await session.open()
        #expect(session.phase == .failed(.ankiClosed))
        await mock.setFailure(nil)
        await session.open()
        #expect(session.phase == .front(c1))
        #expect(await mock.enteredDecks == ["A", "A"])
    }

    @Test func otherApiErrorIsAnkiError() async {
        let (session, mock) = make([("A", [makeCard(1)])])
        await mock.setFailure(.api("boom"))
        await session.open()
        #expect(session.phase == .failed(.other))
        #expect(session.phase.message == "Anki error")
    }
}
