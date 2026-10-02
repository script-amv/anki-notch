import Foundation

/// The AnkiConnect actions AnkiNotch uses. The session depends on this
/// protocol only; `MockAnkiConnectClient` backs tests and Anki-free UI work.
public protocol AnkiConnectClient: Sendable {
    func deckNames() async throws -> [String]
    func deckStats(decks: [String]) async throws -> [DeckStats]
    func startReview(deckName: String) async throws
    func currentCard() async throws -> CurrentCard
    func startCardTimer() async throws
    func showAnswer() async throws
    func answerCurrentCard(ease: Int) async throws
    /// Anki's own undo (`guiUndo`): takes back its latest operation. It only
    /// schedules the undo, and Anki's reviewer stays stale until it is
    /// re-entered; see `ReviewSession.undo()`.
    func undo() async throws
    func mediaDirPath() async throws -> String
}

/// Live implementation: AnkiConnect's JSON-over-HTTP protocol, API version 6.
public actor AnkiConnectHTTPClient: AnkiConnectClient {
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8765")!
    public static let apiVersion = 6

    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL = AnkiConnectHTTPClient.defaultEndpoint,
                session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            // Short: a frozen Anki (App Nap does this) must not leave the panel
            // blank for long before it says so.
            config.timeoutIntervalForRequest = 5
            self.session = URLSession(configuration: config)
        }
    }

    public func deckNames() async throws -> [String] {
        try await invoke("deckNames")
    }

    public func deckStats(decks: [String]) async throws -> [DeckStats] {
        // Keyed by deck id; the order that matters to callers is by name.
        let byId: [String: DeckStats] = try await invoke("getDeckStats", params: ["decks": decks])
        return byId.values.sorted { $0.name < $1.name }
    }

    public func startReview(deckName: String) async throws {
        try await invokeAccepted("guiDeckReview", params: ["name": deckName])
    }

    public func currentCard() async throws -> CurrentCard {
        try await invoke("guiCurrentCard")
    }

    public func startCardTimer() async throws {
        try await invokeAccepted("guiStartCardTimer")
    }

    public func showAnswer() async throws {
        try await invokeAccepted("guiShowAnswer")
    }

    public func answerCurrentCard(ease: Int) async throws {
        try await invokeAccepted("guiAnswerCard", params: ["ease": ease])
    }

    public func undo() async throws {
        try await invokeAccepted("guiUndo")
    }

    public func mediaDirPath() async throws -> String {
        try await invoke("getMediaDirPath")
    }

    // MARK: Transport

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: String?
    }

    /// GUI actions answer `true`, or `false` when the reviewer isn't in the
    /// state the action needs. `false` is not an error to AnkiConnect, so it
    /// is turned into one here rather than silently read as success.
    private func invokeAccepted(
        _ action: String, params: [String: any Sendable]? = nil
    ) async throws {
        let accepted: Bool = try await invoke(action, params: params)
        guard accepted else { throw AnkiConnectError.declined(action) }
    }

    private func invoke<T: Decodable>(
        _ action: String, params: [String: any Sendable]? = nil
    ) async throws -> T {
        var body: [String: Any] = ["action": action, "version": Self.apiVersion]
        if let params { body["params"] = params }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw AnkiConnectError.unreachable(error.localizedDescription)
        }

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw AnkiConnectError.malformedResponse
        }
        if let message = envelope.error { throw AnkiConnectError.api(message) }
        guard let result = envelope.result else { throw AnkiConnectError.malformedResponse }
        return result
    }
}
