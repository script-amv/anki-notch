# Handoff: Settings, first setting "Force black background"

Written 2026-10-02 at the end of the chat that built v1 and the expand
animation. **Build this in a new chat** (see "Working conventions" in
`CLAUDE.md`). Start with the brainstorming skill; this note is input to it, not
a design.

## The request, as given

> Make settings for this app. First setting to include: a "force black
> background" checkbox that overwrites the background from the default to a
> black one, so black background for all notes.

Only that one setting for now. The point is that this is the first of several,
so the settings mechanism itself (where it lives, how values are stored and
applied) is part of the job, kept as small as one setting allows.

## State of the repo

- `main` has only the two docs commits. `build/v1` (the app, reviewed and
  fixed) and `feature/expand-animation` (branched from `build/v1`, adds the
  notch-growth animation) are **not merged**; the user has not yet said how to
  land them. Branch the new work from `feature/expand-animation`, or ask first
  whether to merge locally.
- 46 tests pass (`make test`). No Xcode on this machine, only the Command Line
  Tools: no `xcodebuild`, no SwiftUI previews; `make app` builds a signed
  bundle by script. The UI layer (`Sources/AnkiNotch`) has no unit tests; logic
  worth testing belongs in `AnkiNotchKit`.
- Read `CLAUDE.md` first: it lists the invariants that are easy to break.

## What the app is today (relevant parts)

- A background app (`LSUIElement`, no Dock icon). Its only chrome is a status
  item whose single entry is **Quit** (`Sources/AnkiNotch/StatusItem.swift`).
  There is **no settings UI and no stored preference of any kind** yet.
- Cards render in a `WKWebView` (`CardWebView.swift`). The document comes from
  `CardDocument.html(side:css:)` in `AnkiNotchKit`: a base `<style>` (system
  light/dark via `color-scheme`, and Anki's `nightMode`/`night_mode` body
  classes mirrored from the system), then the **note type's own CSS**, then the
  card HTML in `<div id="qa">` under `<body class="card isMac">`. The note CSS
  comes after ours, so it wins on specificity ties; stock note types set
  `.card { color: black; background-color: white }`.
- The panel's top strip (notch height) is already black, and the panel is a
  non-activating key panel at `mainMenu + 1`.
- Settings that change what a visible card looks like need the card to
  re-render; `CardWebView.show` skips the load when the document string is
  unchanged, so a changed document (a new parameter feeding `html`) reloads
  naturally.

## Questions the brainstorm should settle

1. **What "black background" means for readability.** Forcing only the
   background leaves stock cards with black text on black. Options to weigh:
   also force a light text colour; or force Anki's night-mode classes (and a
   dark web-view appearance) so note types that support night mode switch
   themselves, then override the background; or invert. What about images with
   white backgrounds, and note types that style `#qa` or inner elements with
   their own backgrounds? Specificity: `!important`, or a `<style>` placed after
   the note CSS.
2. **Where settings live in the UI.** A "Settings…" item in the status-item
   menu opening a small window is the obvious home. Notes from the reference
   app (`~/Developer/reviewbar-for-anki/CLAUDE.md`) that bite here: an
   accessory app must be activated before a window comes forward, and a normal
   window opens *underneath* a panel at `mainMenu + 1`, so the settings window
   needs a level above it while key. The status item can end up hidden behind
   the notch on a crowded menu bar, so consider a second way in.
3. **Storage and plumbing.** `UserDefaults` with a small typed wrapper in
   `AnkiNotchKit` (pure, testable, with defaults) is the likely shape; decide
   how the value reaches `CardDocument.html` and whether a change applies live
   to an open panel.
4. **Interaction with the open panel.** Opening settings while the panel is up
   (the panel collapses when the mouse leaves; focus and key handling must not
   fight the settings window).
5. **How to test it.** Pure part: the document/CSS produced for each setting
   value, and the defaults/storage wrapper. UI part: manual checklist (checkbox
   toggles the card, persists across relaunch).

## Not part of this request

More settings, a general preferences framework beyond what one checkbox needs,
changes to the review flow, audio.
