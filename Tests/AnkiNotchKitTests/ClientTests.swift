import Foundation
import Testing
@testable import AnkiNotchKit

/// Answers every request with a canned body (or failure) and records the JSON
/// that was posted.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: Result<Data, Error> = .success(Data())
    nonisolated(unsafe) static var lastBody: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        if let body {
            Self.lastBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
        switch Self.response {
        case .success(let data):
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func stubbedClient(returning json: String) -> AnkiConnectHTTPClient {
    StubURLProtocol.response = .success(Data(json.utf8))
    StubURLProtocol.lastBody = nil
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return AnkiConnectHTTPClient(session: URLSession(configuration: config))
}

@Suite(.serialized) struct ClientTests {
    @Test func sendsActionVersionAndParams() async throws {
        let client = stubbedClient(returning: #"{"result": true, "error": null}"#)
        try await client.answerCurrentCard(ease: 3)
        let body = try #require(StubURLProtocol.lastBody)
        #expect(body["action"] as? String == "guiAnswerCard")
        #expect(body["version"] as? Int == 6)
        #expect((body["params"] as? [String: Int]) == ["ease": 3])
    }

    @Test func decodesGuiCurrentCardPayload() async throws {
        let client = stubbedClient(returning: """
            {"result": {"cardId": 1, "question": "q", "answer": "a", "css": ".card{}",
            "buttons": [1,2,3,4], "deckName": "Sample", "modelName": "Basic",
            "nextReviews": [], "fields": {}}, "error": null}
            """)
        let card = try await client.currentCard()
        #expect(card == CurrentCard(cardId: 1, question: "q", answer: "a", css: ".card{}",
                                    buttons: [1, 2, 3, 4], deckName: "Sample"))
    }

    @Test func deckStatsAreSortedByName() async throws {
        let client = stubbedClient(returning: """
            {"result": {
              "2": {"deck_id": 2, "name": "B", "new_count": 1, "learn_count": 2, "review_count": 3},
              "1": {"deck_id": 1, "name": "A", "new_count": 0, "learn_count": 0, "review_count": 5}
            }, "error": null}
            """)
        let stats = try await client.deckStats(decks: ["A", "B"])
        #expect(stats.map(\.name) == ["A", "B"])
        #expect(stats.map(\.dueTotal) == [5, 6])
    }

    @Test func errorFieldBecomesApiError() async {
        let client = stubbedClient(returning: #"{"result": null, "error": "boom"}"#)
        await #expect(throws: AnkiConnectError.api("boom")) { try await client.deckNames() }
    }

    @Test func aFalseResultIsDeclined() async {
        // AnkiConnect answers `false` (not an error) when the reviewer isn't
        // where the request assumes: not active, answer not shown, bad ease.
        let calls: [(String, @Sendable (AnkiConnectHTTPClient) async throws -> Void)] = [
            ("guiShowAnswer", { try await $0.showAnswer() }),
            ("guiAnswerCard", { try await $0.answerCurrentCard(ease: 3) }),
            ("guiStartCardTimer", { try await $0.startCardTimer() }),
            ("guiDeckReview", { try await $0.startReview(deckName: "A") }),
        ]
        for (action, call) in calls {
            let client = stubbedClient(returning: #"{"result": false, "error": null}"#)
            await #expect(throws: AnkiConnectError.declined(action)) { try await call(client) }
        }
    }

    @Test func garbageBodyIsMalformedResponse() async {
        let client = stubbedClient(returning: "not json")
        await #expect(throws: AnkiConnectError.malformedResponse) {
            try await client.deckNames()
        }
    }

    @Test func connectionFailureIsUnreachable() async {
        let client = stubbedClient(returning: "")
        StubURLProtocol.response = .failure(URLError(.cannotConnectToHost))
        await #expect {
            try await client.deckNames()
        } throws: { error in
            if case AnkiConnectError.unreachable = error { return true }
            return false
        }
    }
}

@Suite struct ModelTests {
    @Test func isReviewInactiveMatchesAnkisMessage() {
        #expect(AnkiConnectError.api("Gui review is not currently active.").isReviewInactive)
        #expect(!AnkiConnectError.api("deck not found").isReviewInactive)
        #expect(!AnkiConnectError.unreachable("x").isReviewInactive)
    }

    @Test func goodIsEase3OnFourButtonsAndEase2OtherwiseAgainIsEase1() {
        for (buttons, good) in [([1, 2, 3, 4], 3), ([1, 2, 3], 2), ([1, 2], 2)] {
            let card = makeCard(1, buttons: buttons)
            #expect(card.ease(for: .good) == good)
            #expect(card.ease(for: .again) == 1)
        }
    }
}
