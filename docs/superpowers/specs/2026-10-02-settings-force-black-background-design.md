# Settings: "Force black background" — design

Date: 2026-10-02. Input: `docs/handoff/2026-10-02-settings-force-black-background.md`.

## Goal

Add a settings mechanism, kept as small as one setting allows, and ship its first
setting: **Force black background**. Checked, every card is shown on black
whatever its note type's CSS says. Unchecked, cards render exactly as today.

Success: the checkbox changes how the card looks, the choice survives a
relaunch, the review flow is untouched, and the new logic is covered by tests
written first in `AnkiNotchKit`.

Out of scope: further settings, a general preferences framework, review-flow
changes, audio, any second way to open the settings window.

## Decisions (agreed in brainstorming)

1. **Meaning of "black".** Force Anki's night mode, then make the canvas pure
   black (option A). Stock note types become light-on-black through the existing
   `body.nightMode` rule; note types with their own `.nightMode` CSS switch
   themselves. Not a background-only override (black text on black) and not a
   forced text colour.
2. **Entry point.** A "Settings…" item (⌘,) in the status-item menu, nothing else.
   Known limitation: on a crowded menu bar the status item can sit behind the
   notch, and then settings cannot be reached. Accepted.
3. **Applies immediately**, no Save button. An open card re-renders live.

## Kit side (`AnkiNotchKit`, pure)

### `AppSettings`

`@MainActor @Observable final class AppSettings`, over an injected
`UserDefaults` (tests pass a throwaway suite).

- `forceBlackBackground: Bool`, default `false`, stored under the key
  `forceBlackBackground`. Setting it writes through to the defaults.
- Typed properties, no registry: the next setting is one more property.

### `CardDocument.html(side:css:forceBlackBackground:)`

New parameter, default `false`; with `false` the output is byte-identical to
today. With `true`:

- `<html>` carries class `night-mode`; `<body>` is `card isMac nightMode
  night_mode`. Note CSS keyed on those classes applies from the first paint.
- `:root` gets `color-scheme: dark` (scrollbars, form controls).
- The `matchMedia` script is omitted, so a light system appearance cannot
  remove the forced classes.
- A final `<style>` **after the note CSS** sets
  `html, body.card, #qa { background: #000 !important }`. `!important` beats
  the stock `.card { background-color: white }` and any `#qa` rule.
- Inner elements keep their own backgrounds (images, tables). A note that paints
  a light box inside the card still shows it.

## App side (`Sources/AnkiNotch`, manual checklist)

- **`AppDelegate`** owns one `AppSettings(defaults: .standard)`. `render()` reads
  `settings.forceBlackBackground` inside the existing `withObservationTracking`,
  so toggling re-renders the visible card. `CardWebView.show` gains a
  `forceBlackBackground:` argument passed to `CardDocument.html`; its existing
  "skip load when the document string is unchanged" check reloads on a change
  and keeps the snapshot swap.
- **`SettingsWindow`**: a small `NSWindow` hosting a SwiftUI `Toggle` bound to
  `AppSettings`. Opening it calls `NSApp.activate`, sets the window level above
  the panel's `mainMenu + 1`, and `makeKeyAndOrderFront`. The window is created
  once and reused.
- **`StatusItem`** gets "Settings…" above "Quit AnkiNotch", wired through a
  callback from `AppDelegate`.
- **Key monitor guard (`PanelController.installKeyMonitor`).** The monitor is a
  local monitor for the whole app and swallows every unmodified space / `1`.
  With the settings window key that would stop space toggling the checkbox, and
  with a card on its back it would answer the card (Good) unseen, violating
  "never grade a card the user didn't see". Fix: act only on events whose
  `event.window` is the panel; pass all others through. The review logic is not
  touched. The window test is a one-line condition in the UI layer; the
  key-code mapping stays where it is.
- **Open panel.** It collapses on its own when the mouse leaves, so it normally
  hides while settings are edited and the next hover shows the new look. If it
  is still open during a toggle, it re-renders live.

## Tests

Written first, in `AnkiNotchKitTests`:

- `CardDocumentTests`: default output unchanged (stable substrings plus equality
  with the explicit `false` call); forced output contains the three night-mode
  classes, `color-scheme: dark`, the `!important` black rule positioned after the
  note CSS, and no `matchMedia`.
- `AppSettingsTests`: default is `false`; a set value persists to a new instance
  over the same suite; changing the value triggers observation.

Manual checklist (`ANKINOTCH_MOCK=1`, never the real collection):

1. Settings… opens a window above the panel; ⌘, works with the menu open.
2. Toggling turns a sample card black with light text, and back, with no flash.
3. The choice persists across relaunch (`make app` bundle too).
4. With a card on its back, space in the settings window toggles the checkbox
   and does **not** answer the card; space in the panel still flips/answers.
5. `make test` stays green (46 existing tests plus the new ones).

## Risks

- Stock `#qa`-less note types are covered by the `body.card` rule; a note type
  that paints its background on an inner wrapper will keep it (accepted, above).
- `@Observable` property writes happen on the main actor; `AppSettings` is
  `@MainActor`, matching `ReviewSession`.
