# AnkiNotch — design

Date: 2026-10-02 · Status: draft for review

## Purpose

Review Anki cards with the least possible friction. Hover the notch and the
current card appears, nothing else. Space flips it; space or `1` answers; the
next card appears at once. No buttons, badges, settings, reminders or chrome.

Built from scratch for the author's own use. `reviewbar-for-anki`
(`~/Developer/reviewbar-for-anki`, MIT) is **reference only** — its Anki flow
and the problems it hit are borrowed; its code and structure are not.

## Scope

**In v1**

- macOS background app with no Dock icon (`LSUIElement`), plus a status item whose
  only entry is **Quit**.
- Hover over the notch → a borderless panel hangs from it showing the current
  card. Mouse leaves → it collapses.
- Always reviews all decks, in Anki's own order. No deck selection or memory.
- Anki stays the only scheduler; driven through the AnkiConnect add-on
  (`http://127.0.0.1:8765`, API v6).
- Card rendering: the note type's HTML, CSS, JavaScript and images.

**Not in v1** — audio (markers are stripped, nothing plays), Hard/Easy answers,
undo, bury/suspend, deck choice, settings, badge/counts, reminders,
notifications, launch-at-login, updates, sync.

## Behavior

### Hover and focus

- An invisible hotspot window sits over the notch of each screen (the notch
  rect from `NSScreen` safe-area/auxiliary areas). On screens without a notch,
  a virtual hotspot at top-center, about 200 pt wide and one menu-bar high.
- Hover over the hotspot → the panel expands on **that** screen. Expanding
  records `NSWorkspace.shared.frontmostApplication`, activates AnkiNotch and
  makes the panel the key window, so keystrokes reach it.
- The mouse leaving the union of hotspot and panel starts a ~250 ms grace
  timer; re-entering cancels it. When it fires the panel hides and the
  recorded app is re-activated — unless the user already switched to another
  app in the meantime, in which case focus is left alone.

### Panel

- Borderless `NSPanel` above the menu bar (`mainMenu + 1`), top edge flush with
  the top of the screen, horizontally centered on the notch.
- Width fixed at 320 pt. Height follows the card: the web view reports its
  content height; the panel is clamped to **160–560 pt** and animates height
  changes (front→back, next card). A taller card scrolls inside the panel.
- Shape: black strip the height of the notch/menu bar (so it reads as the notch
  growing), then the card, with rounded bottom corners (~20 pt). The card area
  is the web view only — no padding, no controls.

### Keys (a local key monitor on the panel; the web view would swallow them)

| Phase        | Space                         | `1`           | Other keys |
|--------------|-------------------------------|---------------|------------|
| front        | flip to back                  | ignored       | pass through |
| back         | answer **Good**               | answer **Again** | pass through |
| loading / submitting / terminal | ignored    | ignored       | pass through |

"Good" is ease 3 on a four-button card and ease 2 on a three-button card
(decided from the card's button list, never from a fixed number). "Again" is
ease 1. Keys are ignored while a request is in flight, so a held key cannot
double-answer.

### Review flow (all through AnkiConnect; GUI-driven, which is the only correct queue)

1. **First hover / after "all done" / after an error:** list decks, take the
   top-level ones (no `::`), skip those with nothing due (`getDeckStats`), and
   `guiDeckReview` the first. Then `guiCurrentCard` → `guiStartCardTimer`.
   No prefetch before the first hover: entering the reviewer changes what
   Anki's own window shows. A ~100 ms blank panel on that first hover is
   expected.
2. **Flip:** `guiShowAnswer`.
3. **Answer:** `guiAnswerCard(ease)`, then immediately `guiCurrentCard` +
   `guiStartCardTimer` for the next card.
4. **"Review is not currently active"** is *success*, not failure: the deck is
   drained → move to the next top-level deck; none left → **All done**.
5. **Hover again mid-card:** call `guiCurrentCard` and compare card ids. Same
   card → show it on the side it was left on. Different or inactive (the user
   reviewed in Anki itself) → discard local state and start from step 1.
   The deck is never re-entered while a card is current, so nothing is
   re-gathered or skipped.
6. Never call `getIntervals` or `getLatestReviewID` (both write to the
   collection).

### Terminal and error states

Never a blank or spinning panel. One centered line of small text on the same
panel: **All done**, **Open Anki** (connection refused/unreachable, or
AnkiConnect missing), **Anki error** (any other failure). The next hover
retries from step 1.

## Rendering

- `WKWebView`, non-persistent data store, JavaScript on (note types use it).
- Card HTML is placed in `<div id="qa">` as a direct child of
  `<body class="card isMac">`, because note-type CSS matches on that shape.
  The answer side is rendered exactly as `guiCurrentCard` returns it (Anki
  repeats the question above `<hr id=answer>`); trimming that repeat is a
  possible later tweak, not v1.
- Audio markers (`[sound:…]`, `[anki:play:…]`) are stripped from the HTML so
  they never show as text.
- System light/dark: the web view's appearance follows the system, and a small
  injected script mirrors it into Anki's `nightMode` / `night_mode` body
  classes.
- Media: a custom URL scheme handler serves files from Anki's media folder
  (`getMediaDirPath`), rejecting any path that is not a plain file name. It
  returns real HTTP responses (200/404, `Content-Type`, `Content-Length`),
  because card scripts that `fetch` media see a status-less response as
  "HTTP 0". No sandbox: a sandboxed app cannot read the media folder.
- One native bridge only: a one-way `cardHeight` message from a
  `ResizeObserver`, which drives panel height.
- A side change swaps the document without flashing: the previous rendering
  is held as a snapshot until the new page has painted.

## Structure

SwiftPM, Swift 6, macOS 15+. Two targets so logic is testable without Anki or
a UI:

- **`AnkiNotchKit`** (library, no AppKit/WebKit)
  - `AnkiConnectClient` protocol, `AnkiConnectHTTPClient` (JSON envelope
    `{result, error}`), `MockAnkiConnectClient`; the UI and session depend on
    the protocol only.
  - `ReviewSession` — the state machine: `loading → front → back →
    submitting → front …`, with `allDone` and `unavailable`.
  - `CardHTML` — DOM wrapper, audio-marker stripping.
  - `AnkiMedia` — media path validation and MIME types.
  - `PanelGeometry` — placement under the notch and the height clamp.
- **`AnkiNotch`** (executable, AppKit)
  - `NotchHotspotController`, `PanelController` (hover, grace timer, focus
    hand-back, animated resizing, key monitor), `CardWebView` +
    `MediaSchemeHandler`, `StatusItem` (Quit), app entry point.

## Testing

- **Unit (Swift Testing, mock client):** flip then answer; Good = ease 3 on a
  four-button card and ease 2 on a three-button card; Again = ease 1; a
  drained deck advances to the next and the last one gives all-done; mid-card
  re-hover keeps card and side, and a changed card id resets; duplicate
  answers ignored while submitting; unreachable → unavailable; the height
  clamp; DOM wrapper output; audio-marker stripping; media path validation.
- **Manual checklist for the panel** (cannot be unit-tested): hover expands
  and takes focus; space and `1` work; leaving collapses and restores the
  previous app; height animates between sides; terminal-state text shows.
- **No Xcode on this machine.** `swift test` needs the Command Line Tools'
  Testing framework on its search paths; a Makefile target carries the flags.

## Build and run

- `make run` → `swift run AnkiNotch` during development.
- `make app` → assembles `AnkiNotch.app` from the built binary and an
  `Info.plist` (`LSUIElement`), ad-hoc signed (`codesign -s -`), installed to
  `~/Applications`. Personal use: no notarization. A real bundle also lets the
  UI be driven and checked with screenshots.
- Local git repo only; no remote created.

## Open items

- Whether the answer side should hide the repeated question — deliberately
  left as Anki renders it for v1.
- Panel width (320) and height clamp (160–560) are starting values; both are
  single constants.
