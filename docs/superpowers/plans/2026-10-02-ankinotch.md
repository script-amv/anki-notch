# AnkiNotch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A background macOS app: hover the notch → the current Anki card appears (nothing else); space flips; space = Good, `1` = Again; next card at once.

**Architecture:** SwiftPM, two targets. `AnkiNotchKit` (no AppKit/WebKit) holds the AnkiConnect client, the review state machine, card HTML and media helpers, and panel geometry — all unit-tested against a mock. `AnkiNotch` (AppKit) holds the notch hotspot, borderless panel, card web view, key monitor and Quit status item. Anki stays the only scheduler, driven through the GUI review flow.

**Tech Stack:** Swift 6, macOS 15+, AppKit, WebKit, Swift Testing, AnkiConnect API v6.

**Spec:** `docs/superpowers/specs/2026-10-02-ankinotch-design.md`

**Reference (read-only, never edited):** `~/Developer/reviewbar-for-anki` — port ideas and helper logic from it where a task says so; do not copy its structure.

## Global Constraints

- Project at `~/Developer/AnkiNotch`; local git only, no remote.
- Swift 6 (`swift-tools-version:6.0`), platform `.macOS(.v15)`; targets `AnkiNotchKit`, `AnkiNotch`, tests `AnkiNotchKitTests`.
- AnkiConnect at `http://127.0.0.1:8765`, request `{"action", "version": 6, "params"}`, response `{"result", "error"}`.
- Always all decks: top-level decks only (names without `::`), in `deckNames` order, skipping decks with nothing due.
- Review flow is GUI-driven: `guiDeckReview` → `guiCurrentCard` → `guiStartCardTimer` → `guiShowAnswer` → `guiAnswerCard`. Never call `getIntervals` or `getLatestReviewID`.
- "Review is not currently active" is success (deck drained), not an error.
- Good = ease 3 on a four-button card, ease 2 otherwise; Again = ease 1. Only space and `1` are bound; all other keys pass through.
- Panel: borderless, level `mainMenu + 1`, flush with screen top, centered on the notch; width 320 pt; card height clamped to 160–560 pt; rounded bottom corners 20 pt; collapse grace 250 ms.
- Terminal text, exactly: `All done`, `Open Anki`, `Anki error`. Never a blank or spinning panel.
- Card DOM: card HTML inside `<div id="qa">`, a direct child of `<body class="card isMac">`; one native bridge only (`cardHeight`).
- No audio: `[sound:…]`, `[anki:play:…]` and `[anki:tts …]…[/anki:tts]` are stripped. No sandbox.
- Not in v1: audio, Hard/Easy, undo, bury/suspend, deck choice, settings, badge, reminders, notifications, launch-at-login, updates, sync.
- No Xcode on this machine: tests run through the Command Line Tools' Testing framework flags carried by the Makefile.

## Review Focus

Spec is silent on these; each has a test in the named task.

1. Anki closed or restarted mid-card, then hovered again → must recover with a fresh start, not stay stuck (Task 2).
2. Key held down / key repeat on the back → must answer exactly once (Task 2).
3. Collection with nothing due anywhere → `All done` on first hover, never a blank panel (Task 2).
4. TTS blocks and sound markers in card HTML → must never show as text (Task 3).
5. Deck names with spaces, unicode and `::` subdecks → top-level only, entered by exact name (Task 2).

## File Structure

```
Package.swift  Makefile  .gitignore  CLAUDE.md
scripts/make-app.sh
Sources/AnkiNotchKit/   Models.swift  AnkiConnectClient.swift  MockAnkiConnectClient.swift
                        ReviewSession.swift  CardDocument.swift  MediaFiles.swift  PanelGeometry.swift
Sources/AnkiNotch/      main.swift  AppDelegate.swift  StatusItem.swift
                        NotchHotspotController.swift  PanelController.swift
                        CardWebView.swift  MediaSchemeHandler.swift
Tests/AnkiNotchKitTests/ ClientTests.swift  ReviewSessionTests.swift  CardDocumentTests.swift
                         MediaFilesTests.swift  PanelGeometryTests.swift  TestSupport.swift
```

---

### Task 1: Package, Makefile and AnkiConnect client

**Files:**
- Create: `Package.swift`, `Makefile`, `.gitignore` (`.build/`, `*.app`), `Sources/AnkiNotchKit/Models.swift`, `AnkiConnectClient.swift`, `MockAnkiConnectClient.swift`, `Sources/AnkiNotch/main.swift` (empty `import AppKit` placeholder so the target builds), `Tests/AnkiNotchKitTests/ClientTests.swift`, `TestSupport.swift`

**Interfaces:**
- Produces (`Models.swift`):
  - `public enum Rating: Sendable { case again, good }`
  - `public struct CurrentCard: Decodable, Sendable, Equatable { cardId: Int64; question: String; answer: String; css: String; buttons: [Int]; deckName: String; public init(cardId:question:answer:css:buttons:deckName:); public func ease(for rating: Rating) -> Int }`
  - `public struct DeckStats: Decodable, Sendable, Equatable { deckId: Int64; name: String; newCount, learnCount, reviewCount: Int; public init(...); var dueTotal: Int }` (snake_case keys `deck_id`, `new_count`, `learn_count`, `review_count`)
  - `public enum AnkiConnectError: Error, Equatable, Sendable { case unreachable(String), api(String), malformedResponse; var isReviewInactive: Bool }` (case-insensitive match on `"review is not currently active"`)
- Produces (`AnkiConnectClient.swift`):
  - `public protocol AnkiConnectClient: Sendable { func deckNames() async throws -> [String]; func deckStats(decks: [String]) async throws -> [DeckStats]; func startReview(deckName: String) async throws; func currentCard() async throws -> CurrentCard; func startCardTimer() async throws; func showAnswer() async throws; func answerCurrentCard(ease: Int) async throws; func mediaDirPath() async throws -> String }`
  - `public actor AnkiConnectHTTPClient: AnkiConnectClient { public init(endpoint: URL = defaultEndpoint, session: URLSession? = nil) }` — default session is ephemeral with a 10 s timeout. Actions: `deckNames`, `getDeckStats {decks}` (result is an object keyed by deck id → sorted by `name`), `guiDeckReview {name}`, `guiCurrentCard`, `guiStartCardTimer`, `guiShowAnswer`, `guiAnswerCard {ease}`, `getMediaDirPath`.
- Produces (`MockAnkiConnectClient.swift`, public so UI can use it): `public actor MockAnkiConnectClient: AnkiConnectClient { init(decks: [(name: String, cards: [CurrentCard])]); answered: [(cardId: Int64, ease: Int)]; enteredDecks: [String]; timerStarts: Int; func setFailure(_ error: AnkiConnectError?); func discardCurrentCard() }`. Behaviour: `deckNames` returns names in order; `deckStats` reports `reviewCount = cards.count`; `startReview` makes that deck active (inactive if empty); `currentCard`/`showAnswer` throw `.api("Gui review is not currently active.")` when inactive; `answerCurrentCard` throws `.api("Not in answer state")` unless `showAnswer` was called, then pops the card, resets answer-shown, and deactivates when the queue empties; `discardCurrentCard` pops the current card as if answered in Anki itself (no `answered` entry); any call throws the failure set by `setFailure`. `mediaDirPath` returns `"/tmp/ankinotch-media"`. `MockAnkiConnectClient.sampleCards: [CurrentCard]` (two cards, one with four buttons, one with three).
- `TestSupport.swift`: `func makeCard(_ id: Int64, deck: String = "A", buttons: [Int] = [1,2,3,4]) -> CurrentCard` with `question: "Q\(id)"`, `answer: "Q\(id)<hr id=answer>A\(id)"`, empty css.

- [ ] **Step 1: Write the failing tests** in `ClientTests.swift`, using a `StubURLProtocol` (registered via `URLSessionConfiguration.protocolClasses`) that records the request body and returns a canned response or throws:
  - `sendsActionVersionAndParams`: `answerCurrentCard(ease: 3)` posts JSON equal to `["action": "guiAnswerCard", "version": 6, "params": ["ease": 3]]`.
  - `decodesGuiCurrentCardPayload`: canned `{"result": {"cardId": 1, "question": "q", "answer": "a", "css": ".card{}", "buttons": [1,2,3,4], "deckName": "Sample", "modelName": "Basic", "nextReviews": [], "fields": {}}, "error": null}` → `CurrentCard` with those values (extra keys ignored).
  - `deckStatsAreSortedByName`: canned object with ids `"2"`→"B", `"1"`→"A" returns `["A", "B"]` and `dueTotal == new+learn+review`.
  - `errorFieldBecomesApiError`: `{"result": null, "error": "boom"}` → throws `.api("boom")`.
  - `garbageBodyIsMalformedResponse`; `connectionFailureIsUnreachable` (stub throws `URLError(.cannotConnectToHost)`).
  - `isReviewInactiveMatchesAnkisMessage`: `.api("Gui review is not currently active.")` true; `.api("deck not found")` false.
  - `goodIsEase3OnFourButtonsAndEase2OtherwiseAgainIsEase1`: `ease(for: .good)` is 3 for `[1,2,3,4]`, 2 for `[1,2,3]`, 2 for `[1,2]`; `.again` is 1 for all.
- [ ] **Step 2: Add the Makefile** with targets `build` (`swift build`), `run` (`swift run AnkiNotch`), `test` (`swift test $(TESTFLAGS)`, plus `--filter "$(FILTER)"` when `FILTER` is set, e.g. `make test FILTER=ReviewSessionTests`). `TESTFLAGS` is empty when `xcode-select -p` is not `/Library/Developer/CommandLineTools`; otherwise `-Xswiftc -F$(FW) -Xlinker -F$(FW) -Xlinker -rpath -Xlinker $(FW) -Xlinker -rpath -Xlinker $(DEV)/Library/Developer/usr/lib` where `FW = $(DEV)/Library/Developer/Frameworks`. Write `Package.swift` and the placeholder files.
- [ ] **Step 3: Run `make test`.** Expected: compile failure on the missing types (red for the right reason).
- [ ] **Step 4: Implement** Models, the HTTP client (port the transport from `reviewbar-for-anki/Sources/ReviewBarKit/AnkiConnectClient.swift`: JSON envelope, transport errors → `.unreachable`, undecodable body → `.malformedResponse`, non-null `error` → `.api`) and the mock.
- [ ] **Step 5: Run `make test`.** Expected: all `ClientTests` pass, output clean.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "Add AnkiConnect client, models and mock"`.

---

### Task 2: ReviewSession state machine

**Files:**
- Create: `Sources/AnkiNotchKit/ReviewSession.swift`, `Tests/AnkiNotchKitTests/ReviewSessionTests.swift`

**Interfaces:**
- Consumes: `AnkiConnectClient`, `CurrentCard`, `Rating`, `AnkiConnectError` (Task 1); `MockAnkiConnectClient`, `makeCard` for tests.
- Produces:
  - `public enum AnkiFailure: Equatable, Sendable { case ankiClosed, other }`
  - `public enum ReviewPhase: Equatable, Sendable { case idle, loading, front(CurrentCard), back(CurrentCard), submitting(CurrentCard), allDone, failed(AnkiFailure); public var message: String? }` — `allDone` → `"All done"`, `failed(.ankiClosed)` → `"Open Anki"`, `failed(.other)` → `"Anki error"`, else nil.
  - `public enum ReviewKey: Sendable { case space, one }`
  - `@MainActor @Observable public final class ReviewSession { public init(client: any AnkiConnectClient); public private(set) var phase: ReviewPhase; public private(set) var mediaDir: String?; public func open() async; public func handle(_ key: ReviewKey) async }`

Behaviour of `open()` (the hover entry point): ignored while `loading`/`submitting`. From `idle`/`allDone`/`failed` → start: `loading`; fetch `mediaDir` (a failure leaves it nil, never fatal); `deckNames` → top-level only → `deckStats` → keep decks with `dueTotal > 0` in `deckNames` order; none → `allDone`; else enter the first via `guiDeckReview`, `currentCard`, `startCardTimer` → `front`. From `front`/`back` → `currentCard()`: same id → keep phase unchanged; different id → `front(new)` and `startCardTimer`; `isReviewInactive` → restart from scratch. Transport error → `failed(.ankiClosed)`, any other error → `failed(.other)`. Deck drained (`isReviewInactive` from `currentCard` or from answering) → next remaining deck, none left → `allDone`.

Behaviour of `handle(_:)`: `.space` on `front` → `showAnswer` → `back`; `.space` on `back` → answer Good; `.one` on `back` → answer Again; every other (key, phase) pair does nothing. Answering sets `submitting` *before* the first `await`, so a second key while in flight is ignored; after a successful answer it fetches the next card (`front`) via the drain rules above.

- [ ] **Step 1: Write the failing tests** (`@MainActor @Suite`; each builds a `MockAnkiConnectClient`):
  - `firstOpenEntersFirstDeckWithDueCardsAndShowsFront` — decks `[("Empty", []), ("日本語 Core", [c1, c2]), ("日本語 Core::Sub", [c3])]`: after `open()`, `phase == .front(c1)`, `enteredDecks == ["日本語 Core"]`, `timerStarts == 1`, `mediaDir == "/tmp/ankinotch-media"`. (Review Focus 5)
  - `spaceFlipsThenAnswersGood` — four-button `c1`: `open`, `.space` → `.back(c1)`, `.space` → `.front(c2)`, `answered == [(1, 3)]`.
  - `oneOnBackAnswersAgain` — answered ease 1.
  - `threeButtonCardGoodIsEase2` — `buttons: [1,2,3]` → ease 2.
  - `oneOnFrontDoesNothing` — phase still `.front(c1)`, `answered` empty.
  - `drainedDeckAdvancesThenAllDone` — decks `A:[c1]`, `B:[c2]`: answering `c1` → `.front(c2)` with `enteredDecks == ["A","B"]`; answering `c2` → `.allDone`, `message == "All done"`.
  - `nothingDueAnywhereIsAllDoneOnFirstOpen` — decks `A: []` → `.allDone`, `enteredDecks` empty. (Review Focus 3)
  - `reopenMidCardKeepsCardAndSide` — after `open` + flip, `open()` again → `.back(c1)` and `enteredDecks.count == 1`.
  - `reopenAfterCardWasReviewedInAnkiShowsNewFront` — `open` → `.front(c1)`; `discardCurrentCard()`; `open()` → `.front(c2)`.
  - `heldKeyAnswersOnlyOnce` — at `.back(c1)`: `async let a: Void = session.handle(.space); async let b: Void = session.handle(.space)`; after both, `answered.count == 1`. (Review Focus 2)
  - `unreachableAnkiThenRecovery` — `setFailure(.unreachable("x"))`, `open` → `.failed(.ankiClosed)`, `message == "Open Anki"`; `setFailure(nil)`, `open` → `.front(c1)`. (Review Focus 1)
  - `ankiClosingMidCardRestartsOnNextOpen` — `.front(c1)`; `setFailure(.unreachable("x"))`; `open` → `.failed(.ankiClosed)`; `setFailure(nil)`; `open` → `.front(c1)` with `enteredDecks == ["A","A"]`. (Review Focus 1)
  - `otherApiErrorIsAnkiError` — `setFailure(.api("boom"))` → `.failed(.other)`, `message == "Anki error"`.
- [ ] **Step 2: Run** `make test FILTER=ReviewSessionTests`. Expected: compile failure, `ReviewSession` not defined.
- [ ] **Step 3: Implement** `ReviewSession` per the behaviour above; keep remaining decks as a private `[String]` and put the error → `AnkiFailure` mapping in one private function.
- [ ] **Step 4: Run** the filtered tests then `make test`. Expected: all pass.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add review session state machine"`.

---

### Task 3: Card document and media files

**Files:**
- Create: `Sources/AnkiNotchKit/CardDocument.swift`, `Sources/AnkiNotchKit/MediaFiles.swift`, `Tests/AnkiNotchKitTests/CardDocumentTests.swift`, `MediaFilesTests.swift`

**Interfaces:**
- Produces:
  - `public enum CardDocument { public static let scheme = "ankinotch-media"; public static let baseURL: URL /* ankinotch-media://collection/ */; public static func html(side: String, css: String) -> String; public static func stripAudioMarkers(_ html: String) -> String }` — `html` strips markers itself, then wraps: port `AnkiMedia.documentHTML` from `reviewbar-for-anki/Sources/ReviewBarKit/AnkiMedia.swift` (keep its `<style>` block and night-mode script verbatim; the body is exactly `<body class="card isMac"><div id="qa">…</div>`).
  - `public enum MediaFiles { public static func fileURL(for requestURL: URL, mediaDir: String) -> URL?; public static func mimeType(for fileURL: URL) -> String }` — port `fileURL`/`mimeType` from the same reference file.

- [ ] **Step 1: Write the failing tests:**
  - `wrapsCardInAnkisReviewerDOM`: `html(side: "<b>hi</b>", css: ".x{}")` contains `<body class="card isMac"><div id="qa"><b>hi</b></div>` and `<style>.x{}</style>`.
  - `stripsSoundAndPlayMarkers`: `"a [sound:x.mp3] b [anki:play:q:0] c [anki:play:a:1]"` → `"a  b  c "`.
  - `stripsTTSBlocksIncludingTheirText`: `"x [anki:tts lang=ja_JP]こんにちは[/anki:tts] y"` → `"x  y"`. (Review Focus 4)
  - `leavesOrdinaryBracketsAlone`: `"[1] and [note]"` unchanged.
  - Media: `plainFilenameResolvesInsideMediaDir`; `traversalIsRejected` (`/../etc/passwd`, `/a/b.png`, `/` → nil); `mimeTypesForCommonImages` (`png` → `image/png`, `jpg` → `image/jpeg`, unknown → `application/octet-stream`).
- [ ] **Step 2: Run** `make test FILTER="CardDocumentTests|MediaFilesTests"`. Expected: fail, types missing.
- [ ] **Step 3: Implement** both enums. `stripAudioMarkers` uses regexes `\[sound:[^\]]*\]`, `\[anki:play:[^\]]*\]`, and a dot-matches-newlines `\[anki:tts[^\]]*\].*?\[/anki:tts\]`.
- [ ] **Step 4: Run** `make test`. Expected: all pass.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add card document wrapper and media path helpers"`.

---

### Task 4: Panel geometry

**Files:**
- Create: `Sources/AnkiNotchKit/PanelGeometry.swift`, `Tests/AnkiNotchKitTests/PanelGeometryTests.swift`

**Interfaces:**
- Produces: `public struct PanelGeometry: Equatable, Sendable { public init(screenFrame: CGRect, visibleFrame: CGRect, notch: CGRect?); public static let panelWidth: CGFloat = 320, minContentHeight: CGFloat = 160, maxContentHeight: CGFloat = 560, cornerRadius: CGFloat = 20, collapseGrace: TimeInterval = 0.25; public static func clampedHeight(_ contentHeight: CGFloat) -> CGFloat; public static func notchRect(screenFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeftArea: CGRect?, auxiliaryTopRightArea: CGRect?) -> CGRect?; public var hotspot: CGRect; public func panelFrame(contentHeight: CGFloat) -> CGRect; public static func keepsPanelOpen(mouse: CGPoint, hotspot: CGRect, panel: CGRect) -> Bool }`
- `hotspot` is the real notch rect, or the virtual one on notchless screens (top-center, 200 pt wide, one menu-bar high — 24 pt when the menu bar auto-hides). `notchRect` and the virtual-notch logic are ported from `reviewbar-for-anki/Sources/ReviewBarKit/PanelGeometry.swift` (fallback notch width 200). `panelFrame` is flush with the screen top, centered on `hotspot.midX`, size `(320, hotspot.height + clampedHeight(contentHeight))`. `keepsPanelOpen` is true when `mouse` lies in `hotspot` ∪ `panel`, edges inclusive.

- [ ] **Step 1: Write the failing tests:**
  - `clampsContentHeight`: 100 → 160, 300 → 300, 900 → 560.
  - `panelFrameHangsFromTheNotch`: screen `(0,0,1512,982)`, notch `(656,950,200,32)`, content 300 → `CGRect(x: 596, y: 650, width: 320, height: 332)`.
  - `notchlessScreenUsesVirtualNotch`: screen `(0,0,1920,1080)`, visible `(0,0,1920,1055)`, notch nil → `hotspot == CGRect(x: 860, y: 1055, width: 200, height: 25)`; content 160 → `CGRect(x: 800, y: 895, width: 320, height: 185)`.
  - `notchRectFromAuxiliaryAreas` (width = right.minX − left.maxX) and `notchRectFallsBackTo200WhenAreasMissing`; `noNotchWhenSafeAreaIsZero`.
  - `keepsPanelOpenInsideHotspotOrPanelOnly`: inside hotspot, inside panel, exactly on an edge → true; a point outside both → false.
- [ ] **Step 2: Run** `make test FILTER=PanelGeometryTests`. Expected: fail, type missing.
- [ ] **Step 3: Implement** `PanelGeometry` per the interface.
- [ ] **Step 4: Run** `make test`. Expected: all pass.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add panel geometry"`.

---

### Task 5: AppKit shell — hotspot, panel, focus, Quit

UI code: no unit tests (TDD exception — AppKit windows); verified manually.

**Files:**
- Create/modify: `Sources/AnkiNotch/main.swift`, `AppDelegate.swift`, `StatusItem.swift`, `NotchHotspotController.swift`, `PanelController.swift`

**Interfaces:**
- Consumes: `PanelGeometry` (Task 4).
- Produces:
  - `@MainActor final class NotchHotspotController { init(onHover: @escaping (NSScreen) -> Void); func rebuild() }` — one transparent, borderless window per `NSScreen` over `PanelGeometry(...).hotspot`, above the menu bar, `NSTrackingArea(.mouseEnteredAndExited, .activeAlways)`; rebuilt on `NSApplication.didChangeScreenParametersNotification`. Read `reviewbar-for-anki/Sources/ReviewBar/NotchHotspotController.swift` for the window-level and tracking pitfalls first.
  - `@MainActor final class PanelController { init(); var contentView: NSView (host for the card); var isVisible: Bool; func show(on screen: NSScreen); func hide(); func resize(contentHeight: CGFloat, animated: Bool); var onKey: ((ReviewKey) -> Void)? }`
- `main.swift` sets `NSApp.setActivationPolicy(.accessory)` and runs `AppDelegate`; `StatusItem` has a single **Quit AnkiNotch** item.

Behaviour: `show` records `NSWorkspace.shared.frontmostApplication` (when not AnkiNotch), calls `NSApp.activate(ignoringOtherApps: true)`, and `makeKeyAndOrderFront`; the panel is a borderless `NSPanel` subclass overriding `canBecomeKey` → true, level `.mainMenu + 1`, transparent background, content with a black top strip of `hotspot.height` then the card area, bottom corners rounded 20 pt. While visible, a 100 ms timer checks `NSEvent.mouseLocation` with `keepsPanelOpen`; after 250 ms continuously outside it calls `hide`. `hide` orders the panel out and re-activates the recorded app only if AnkiNotch is still the frontmost app. A local `NSEvent` key monitor (installed in `show`, removed in `hide`) maps unmodified space (keyCode 49) → `.space` and `1` → `.one`, calls `onKey`, and returns nil to consume; all other events pass through.

- [ ] **Step 1: Implement** the files above; for now `AppDelegate` shows the panel with a placeholder `NSTextField` ("AnkiNotch") of content height 200 on hover.
- [ ] **Step 2: Run `make build`.** Expected: builds with no warnings.
- [ ] **Step 3: Manual check (`make run`):** hovering the notch (or top-center on an external screen) expands the panel under it; moving away collapses it after ≈¼ s; hovering again re-expands; your previous app gets focus back after collapse (type a character into it to confirm); the status item's Quit exits; no Dock icon appears.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "Add notch hotspot, panel, focus hand-back and Quit item"`.

---

### Task 6: Card web view and media handler

UI code, manual verification.

**Files:**
- Create: `Sources/AnkiNotch/CardWebView.swift`, `MediaSchemeHandler.swift`; modify `AppDelegate.swift`

**Interfaces:**
- Consumes: `CardDocument`, `MediaFiles` (Task 3).
- Produces:
  - `final class MediaSchemeHandler: NSObject, WKURLSchemeHandler { var mediaDir: String? }` — resolves with `MediaFiles.fileURL`; answers with `HTTPURLResponse` 200 (with `Content-Type`, `Content-Length`) or 404; no Range support.
  - `@MainActor final class CardWebView: NSView { init(); var onContentHeight: ((CGFloat) -> Void)?; func show(html: String, css: String, mediaDir: String?) }` — `WKWebView` with a non-persistent data store, JS on, the scheme handler registered for `CardDocument.scheme`, document loaded with `CardDocument.baseURL`; one user script posting `document.body.scrollHeight` through a `cardHeight` message from a `ResizeObserver` (port `heightReportScript` from `reviewbar-for-anki/Sources/ReviewBar/CardWebView.swift`); `drawsBackground = false`; when replacing an existing document, hold a snapshot (`takeSnapshot`) over the view until `didFinish` + 80 ms to avoid a flash. The message handler must be weakly held to avoid a retain cycle.

- [ ] **Step 1: Implement** both; `AppDelegate` now hosts a `CardWebView` in the panel and, on hover, shows `MockAnkiConnectClient.sampleCards[0]` front, wiring `onContentHeight` → `panel.resize(contentHeight:animated:)`. (Temporary wiring, replaced in Task 7.)
- [ ] **Step 2: Run `make build`.** Expected: clean.
- [ ] **Step 3: Manual check:** the sample card renders inside the panel with no padding; the panel height follows the content and stays within 160–560 pt; a long card (edit the sample temporarily) scrolls inside at 560; dark and light system appearance both render legibly.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "Add card web view and media scheme handler"`.

---

### Task 7: Wire the review session to the panel

UI wiring, manual verification (with the mock first, then real Anki in Task 8).

**Files:**
- Modify: `Sources/AnkiNotch/AppDelegate.swift`, `PanelController.swift`

**Interfaces:**
- Consumes: `ReviewSession`, `ReviewPhase.message`, `ReviewKey` (Task 2), `CardWebView` (Task 6), `PanelController` (Task 5), `AnkiConnectHTTPClient`.
- Produces: the finished app behaviour.

Behaviour: `AppDelegate` owns `AnkiConnectHTTPClient()` and one `ReviewSession`. A hotspot hover → `panel.show(on:)` then `Task { await session.open() }`. `panel.onKey = { key in Task { await session.handle(key) } }`. The panel observes `session.phase` with `withObservationTracking` (re-armed after every change) and renders: `front(card)` → `card.question`, `back(card)` → `card.answer` through `CardWebView.show(html:css:mediaDir: session.mediaDir)`; `submitting`, `loading` and `idle` keep whatever is on screen; `allDone` and `failed` replace the card with one centered, small, secondary-colour line from `phase.message` at the minimum content height (160). Phase changes never reorder or restyle anything else.

- [ ] **Step 1: Implement** the wiring; remove the Task 6 sample.
- [ ] **Step 2: Run `make test` and `make build`.** Expected: all tests pass, build clean.
- [ ] **Step 3: Manual check against the mock** (launch with `ANKINOTCH_MOCK=1`, which makes `AppDelegate` use `MockAnkiConnectClient` with `sampleCards`): hover → front; space → back; space → next front; `1` on a back → next front; after the last card `All done`; hovering mid-card returns the same card and side; holding space does not skip a card.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "Wire review session to the panel"`.

---

### Task 8: App bundle, project notes, real-Anki check

**Files:**
- Create: `scripts/make-app.sh`, `CLAUDE.md`; modify `Makefile` (`app` target)

- [ ] **Step 1: Write `scripts/make-app.sh`:** `swift build -c release`, assemble `build/AnkiNotch.app` (`Contents/MacOS/AnkiNotch`, `Contents/Info.plist` with `CFBundleIdentifier=com.ankinotch.app`, `CFBundleName`, `CFBundleExecutable=AnkiNotch`, `CFBundlePackageType=APPL`, `LSUIElement=true`, `LSMinimumSystemVersion=15.0`, `NSAppTransportSecurity` → `NSAllowsLocalNetworking=true`), `codesign --force --sign - build/AnkiNotch.app`, copy to `~/Applications/AnkiNotch.app`. `make app` runs it.
- [ ] **Step 2: Write `CLAUDE.md`:** what the app is, the commands, the Global Constraints that are easy to break (GUI-driven flow only, drained deck = success, never `getIntervals`/`getLatestReviewID`, one native bridge, Good-ease rule), and the Xcode-less test flags.
- [ ] **Step 3: Run `make app`.** Expected: `~/Applications/AnkiNotch.app` exists; `codesign -v` exits 0.
- [ ] **Step 4: Real-Anki manual checklist** (Anki running with AnkiConnect). **Answering a card changes the real collection — use a disposable Anki profile for steps 5–6, or have the user do them.** (1) Hover shows a card within ~½ s. (2) Space flips. (3) Panel height follows the card between sides. (4) Mouse away collapses; focus returns to the previous app. (5) Space on the back answers Good and shows the next card at once. (6) `1` answers Again. (7) Reviewing a card in Anki itself, then hovering, shows Anki's new current card. (8) With Anki quit, hover shows `Open Anki`; after starting Anki the next hover recovers. (9) A card with images shows its images; one with audio shows no `[sound:…]` text.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add app bundle script and project notes"`.

---

## Self-Review

- **Spec coverage:** hover/focus/grace (Tasks 4–5), panel size/clamp/shape (4–5, 6), keys (2, 5), review flow incl. drained decks, re-hover verification, error states (2, 7), rendering/DOM/night mode/media/height bridge/snapshot swap (3, 6), audio stripping (3), structure and testing (1–4), build/run/app bundle (1, 8), Quit item (5). No gaps.
- **Type consistency:** `Rating`, `CurrentCard.ease(for:)`, `AnkiConnectClient.answerCurrentCard(ease: Int)`, `ReviewKey`, `ReviewPhase.message`, `PanelGeometry.hotspot/panelFrame/keepsPanelOpen` are defined once and used with the same names in later tasks.
- **Proportion:** the plan is a few times shorter than the code it describes; code appears only as test assertions and signatures.
