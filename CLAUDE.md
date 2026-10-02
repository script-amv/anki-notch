# CLAUDE.md

AnkiNotch: a macOS background app. Hover the notch and the current Anki card
appears (nothing else); space flips; on the back, space = Good and `1` = Again;
the next card shows at once. Anki stays the only scheduler, driven through the
AnkiConnect add-on at `http://127.0.0.1:8765`.

Design: `docs/superpowers/specs/2026-10-02-ankinotch-design.md`.
Plan: `docs/superpowers/plans/2026-10-02-ankinotch.md`.
`~/Developer/reviewbar-for-anki` is reference only.

## Working conventions

- **Every new feature is built in a new chat.** Chats here grow huge and slow;
  a fresh one starts cheap. In the new chat the work follows the usual order
  (brainstorm → spec → plan → build), starting from the repo and the handoff
  note in `docs/handoff/`, not from the old conversation. If a feature request
  arrives in a long chat, don't start it there: write a handoff note and say so.
- **Small features skip the written spec and plan.** For a feature this size (a
  setting, a label, a gesture) brainstorm in chat, agree a short design in the
  conversation, and **build only when the user says so** (e.g. "build it"). No
  spec or plan files, no plan-execution ceremony. Reserve written specs and
  plans for work that restructures the app or adds a subsystem; if unsure
  whether something is that big, ask.
- Bug fixes for a feature you just built can stay in its chat.
- **"All good, merge to main" means two things:** fast-forward/merge the feature
  branch into `main`, then run `make app` to overwrite the installed
  `~/Applications/AnkiNotch.app` (standing permission from the user). Don't kill
  or relaunch a running instance; say it's still the old build until restarted.

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
  `PanelGeometry`, `AppSettings` (typed `UserDefaults` wrapper, one property per
  setting). Everything testable lives here.
- `Sources/AnkiNotch` — AppKit: notch hotspot, panel, card web view, status item
  (Settings…, Quit), settings window.

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
- **Never grade a card the user didn't see**: `answer` re-reads `guiCurrentCard`
  first and shows Anki's card instead if it isn't the one on screen. After an
  answer Anki may still report the old card for a moment (it applies answers in
  the background), so the next fetch re-reads up to 5 × 40 ms before accepting it.
- **AnkiConnect `false` is not success**: `guiShowAnswer`, `guiAnswerCard`,
  `guiStartCardTimer` and `guiDeckReview` answer `false` when the reviewer isn't
  where the request assumes. The client turns it into `AnkiConnectError.declined`;
  the session restarts. The mock behaves the same way — keep it that way.
- **Opening needs a 0.15 s dwell and keys arm 0.25 s after the panel appears**
  (`PanelGeometry.openDwell`/`keyArmDelay`), so merely crossing the notch or a
  keystroke already in flight can't take the keyboard or grade a card.
- **Hovering again mid-card re-checks `guiCurrentCard`**: same card id keeps the
  side; a different one (reviewed in Anki meanwhile) shows a fresh front. The
  deck is never re-entered while a card is current.
- **Panel motion is a mask layer inside a stage window.** The window is the
  full-size transparent stage (`PanelGeometry.stageFrame`) while anything moves
  and shrinks to the card (`panelFrame`) when settled; never animate the window
  frame (it blocks the main thread under a web view) and never let the stage
  stay up at rest (it would eat clicks). The black shape is `maskLayer`
  (top-anchored, so changing its size grows it downward); card content is laid
  out once at final size and only revealed. The hover check uses the *final*
  card frame, not the animating window. Timings live in `PanelMotion`.
- **A layer's `presentation()` lies before its first frame**: it reports the
  final model value, so retargeting a just-started animation from it jumps to
  the end. `PanelController.visibleShape` uses the recorded start value for the
  first ~40 ms; a card-height change arriving mid-open retargets with the same
  spring. Don't read the presentation layer directly.
- **WebKit is warmed at launch** (`CardWebView.warmUp`): the first card load
  otherwise stalls the main thread ~0.25 s and the opening animation hitches.
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
- **The key monitor only handles events aimed at the panel** (`event.window ===
  panel`). It is app-wide, so without that check it would swallow space in the
  settings window and answer a card the user isn't looking at.
- **The settings window sits one level above the panel** (`mainMenu + 2`) and the
  app is activated before it shows; otherwise it opens underneath the panel.
- **Settings reach cards through `CardDocument.html`**, read inside
  `AppDelegate.render()`'s observation tracking, so a toggle re-renders the open
  card. "Force black background" = forced night-mode classes + a last `<style>`
  (after the note CSS) setting `html, body.card, #qa` to `#000 !important`.
  Default output (setting off) must stay byte-identical to the pre-settings document.
- **The deck-route row sits outside the content-height clamp** and is always
  counted in `stageFrame` (`PanelGeometry.routeRowHeight`), so toggling it
  animates the mask like a card-height change and never resizes the window
  mid-motion. Rest frames and the hover check use the route-aware height.
- **Clicks are handled only through the panel's own monitor**
  (`event.window === panel`, point inside the hotspot rect), never on the
  hotspot window. A click on the notch toggles the route row (in memory, reset
  on relaunch); clicks anywhere else pass through.
- **The deck choice is `ReviewSession.chosenDeck`**, in memory only (a relaunch
  starts on all decks). A chosen deck is entered alone, with no due filter (an
  empty deck ends at `All done` by itself, and the choice stays so the next
  hover retries it); a parent includes its subdecks. A chosen deck missing from
  `deckNames` clears the choice and falls back to all decks. A choice made while
  a request is in flight sets `restartPending` and is applied when it finishes.
- **The deck menu is a native `NSMenu` popped under the route row** (`DeckMenu`,
  `DeckTree`). `popUp` blocks in its own tracking loop: never call it inside the
  click monitor (schedule a task), and keep `menuIsOpen` set around it so the
  hover check and the review keys stand down; reset `outsideSince` afterwards.
  The row is clickable only while visible. In `All done` with a deck chosen it
  stays up, naming that deck, so the user can pick another.
- **Audio is out of v1**: `[sound:…]`, `[anki:play:…]` and TTS blocks are stripped.

## Testing against real Anki

Answering a card writes to the collection. Use a disposable Anki profile for
anything that answers cards.
