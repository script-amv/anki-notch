# CLAUDE.md

AnkiNotch: a macOS background app. Hover the notch and the current Anki card
appears (nothing else); space flips; on the back, space = Good and `1` = Again;
the next card shows at once. Anki stays the only scheduler, driven through the
AnkiConnect add-on at `http://127.0.0.1:8765`.

Design: `docs/superpowers/specs/2026-10-02-ankinotch-design.md`.
Plan: `docs/superpowers/plans/2026-10-02-ankinotch.md`.
`~/Developer/reviewbar-for-anki` is reference only.

## Commands

```sh
make test                    # AnkiNotchKit tests, no Anki needed (mock client)
make test FILTER=ReviewSessionTests
make build
make run                     # swift run (bare binary)
make app                     # release build -> ad-hoc signed ~/Applications/AnkiNotch.app
ANKINOTCH_MOCK=1 ...         # canned sample cards instead of Anki
```

No Xcode on this machine: with only the Command Line Tools, `make test` passes
the search paths for the Swift Testing framework (see the Makefile).

## Layout

- `Sources/AnkiNotchKit` — no AppKit/WebKit: AnkiConnect client + mock,
  `ReviewSession` (the state machine), `CardDocument`, `MediaFiles`,
  `PanelGeometry`. Everything testable lives here.
- `Sources/AnkiNotch` — AppKit: notch hotspot, panel, card web view, Quit item.

## Invariants that are easy to break

- **GUI-driven review flow only**: `guiDeckReview → guiCurrentCard →
  guiStartCardTimer → guiShowAnswer → guiAnswerCard`. Never use `getIntervals`
  or `getLatestReviewID` (both write to the collection).
- **"Review is not currently active" is success** (deck drained), not an error.
- **`guiDeckReview` takes one deck**: "all decks" means walking the top-level
  decks that have cards due, in order.
- **Good is ease 3 on a four-button card, ease 2 on a three-button card** —
  decided from the card's button list (`CurrentCard.ease(for:)`).
- **`ReviewSession.answer` sets `.submitting` before its first `await`**; that
  is what stops a repeated key answering twice. Key auto-repeat is also dropped
  in `PanelController`.
- **Hovering again mid-card re-checks `guiCurrentCard`**: same card id keeps the
  side; a different one (reviewed in Anki meanwhile) shows a fresh front. The
  deck is never re-entered while a card is current.
- **No panel state may be blank or spinning**: `All done`, `Open Anki`,
  `Anki error` are shown as one line. The next hover retries.
- **One native bridge** in the web view: the one-way `cardHeight` message.
- **Card DOM**: card HTML in `<div id="qa">`, a direct child of
  `<body class="card isMac">` — note-type CSS matches on that shape.
- **Media**: the scheme handler must answer with real HTTP responses
  (`HTTPURLResponse`), or card scripts that `fetch` see "HTTP 0". No sandbox:
  a sandboxed app cannot read Anki's media folder.
- **Focus**: the panel is a non-activating panel that can become key. Do not
  `NSApp.activate` on hover — macOS refuses an app that was never clicked taking
  the front, so keystrokes would go to the app underneath. Non-activating means
  the previous app stays active and gets the keyboard back when the panel hides.
- **Audio is out of v1**: `[sound:…]`, `[anki:play:…]` and TTS blocks are stripped.

## Testing against real Anki

Answering a card writes to the collection. Use a disposable Anki profile for
anything that answers cards.
