import Testing
@testable import AnkiNotchKit

@MainActor @Suite struct ReviewSessionTests {
    private typealias Decks = [(name: String, cards: [CurrentCard])]

    private func make(_ decks: Decks) -> (ReviewSession, MockAnkiConnectClient) {
        let mock = MockAnkiConnectClient(decks: decks)
        return (ReviewSession(client: mock, stalePollInterval: .milliseconds(1)), mock)
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

    // MARK: Anki and the panel drifting apart

    @Test func answerDoesNotGradeACardAnkiHasMovedPast() async {
        let (c1, c2) = (makeCard(1), makeCard(2))
        let (session, mock) = make([("A", [c1, c2])])
        await session.open()
        await session.handle(.space)
        #expect(session.phase == .back(c1))
        await mock.discardCurrentCard()          // the user reviewed c1 in Anki itself
        await session.handle(.space)
        #expect(await mock.answerAttempts == 0)  // never grade a card the user didn't see
        #expect(session.phase == .front(c2))
    }

    @Test func answerWaitsForAnkiToMoveOnFromTheAnsweredCard() async {
        let c2 = makeCard(2)
        let (session, mock) = make([("A", [makeCard(1), c2])])
        // Anki applies an answer in the background, so right after it the
        // current card can still be the one just answered.
        await mock.setStaleReadsAfterAnswer(3)
        await session.open()
        await session.handle(.space)
        await session.handle(.space)
        #expect(session.phase == .front(c2))
    }

    @Test func aCardThatReallyComesBackIsAcceptedAfterPolling() async {
        let c1 = makeCard(1)
        let (session, mock) = make([("A", [c1, makeCard(2)])])
        await mock.setStaleReadsAfterAnswer(100)  // never moves on within the poll limit
        await session.open()
        await session.handle(.space)
        await session.handle(.space)
        #expect(session.phase == .front(c1))      // gave up waiting, did not hang
    }

    @Test func flipWhenAnkiNoLongerReviewsRestarts() async {
        let (session, mock) = make([("A", [makeCard(1)])])
        await session.open()
        await mock.discardCurrentCard()           // Anki's reviewer ended
        await session.handle(.space)              // guiShowAnswer answers `false`
        #expect(session.phase == .allDone)
    }

    @Test func answerAnkiDeclinesRestartsWithoutGrading() async {
        let c1 = makeCard(1)
        let (session, mock) = make([("A", [c1])])
        await session.open()
        await session.handle(.space)
        await mock.forgetAnswerShown()            // Anki is back on the question side
        await session.handle(.space)
        #expect(await mock.answered.isEmpty)
        #expect(session.phase == .front(c1))
    }

    // MARK: Chosen deck

    @Test func choosingADeckReviewsOnlyThatDeck() async {
        let b1 = makeCard(2, deck: "B")
        let (session, mock) = make([("A", [makeCard(1, deck: "A")]), ("B", [b1])])
        await session.choose("B")
        #expect(session.chosenDeck == "B")
        #expect(session.phase == .front(b1))
        #expect(await mock.enteredDecks == ["B"])
    }

    @Test func aSubdeckCanBeChosen() async {
        let c = makeCard(2, deck: "P::Sub")
        let (session, mock) = make([("P", [makeCard(1, deck: "P")]), ("P::Sub", [c])])
        await session.choose("P::Sub")
        #expect(session.phase == .front(c))
        #expect(await mock.enteredDecks == ["P::Sub"])
    }

    @Test func choosingMidCardRestartsOnTheNewDeckWithoutAnswering() async {
        let b1 = makeCard(2, deck: "B")
        let (session, mock) = make([("A", [makeCard(1, deck: "A")]), ("B", [b1])])
        await session.open()
        await session.handle(.space)
        await session.choose("B")
        #expect(session.phase == .front(b1))
        #expect(await mock.answered.isEmpty)
    }

    @Test func drainingTheChosenDeckIsAllDoneAndTheChoiceStays() async {
        let (session, mock) = make([("A", [makeCard(1, deck: "A")]), ("B", [makeCard(2, deck: "B")])])
        await session.choose("B")
        await session.handle(.space)
        await session.handle(.space)
        #expect(session.phase == .allDone)
        #expect(session.chosenDeck == "B")
        await session.open()  // the next hover retries the same deck, not "A"
        #expect(session.phase == .allDone)
        #expect(await mock.enteredDecks == ["B", "B"])
    }

    @Test func allDecksReturnsToWalkingEveryDeck() async {
        let a1 = makeCard(1, deck: "A")
        let (session, _) = make([("A", [a1]), ("B", [makeCard(2, deck: "B")])])
        await session.choose("B")
        await session.choose(nil)
        #expect(session.chosenDeck == nil)
        #expect(session.phase == .front(a1))
    }

    @Test func aChosenDeckThatNoLongerExistsFallsBackToAllDecks() async {
        let a1 = makeCard(1, deck: "A")
        let (session, mock) = make([("A", [a1])])
        await session.choose("Gone")
        #expect(session.chosenDeck == nil)
        #expect(session.phase == .front(a1))
        #expect(await mock.enteredDecks == ["A"])
    }

    @Test func choosingTheDeckAlreadyChosenWhileACardShowsDoesNothing() async {
        let (session, mock) = make([("A", [makeCard(1, deck: "A")])])
        await session.choose("A")
        await session.handle(.space)
        await session.choose("A")
        #expect(session.phase == .back(makeCard(1, deck: "A")))
        #expect(await mock.enteredDecks == ["A"])
    }

    @Test func aChoiceMadeDuringAnAnswerIsAppliedWhenItFinishes() async {
        let b1 = makeCard(3, deck: "B")
        let (session, mock) = make([
            ("A", [makeCard(1, deck: "A"), makeCard(2, deck: "A")]), ("B", [b1]),
        ])
        await session.open()
        await session.handle(.space)
        let answering = Task { await session.handle(.space) }
        await Task.yield()  // the answer is now in flight: phase .submitting
        await session.choose("B")
        await answering.value
        #expect(session.chosenDeck == "B")
        #expect(session.phase == .front(b1))
        #expect(await mock.answered == [MockAnswer(cardId: 1, ease: 3)])
    }

    @Test func availableDecksListsAnkisDecksAndIsNilWhenUnreachable() async {
        let (session, mock) = make([("A", []), ("A::Sub", [])])
        #expect(await session.availableDecks() == ["A", "A::Sub"])
        await mock.setFailure(.unreachable("down"))
        #expect(await session.availableDecks() == nil)
    }
}
