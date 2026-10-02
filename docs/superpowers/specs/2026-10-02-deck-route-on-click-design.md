# Deck route on notch click — design

Date: 2026-10-02. Branch: `feature/deck-route-on-click` (from `main`).

## Goal

Clicking the notch area toggles a row at the top of the open panel that shows
the current card's deck route (`Languages › Japanese › Core`). Hover keeps
opening the panel exactly as today.

User's words: "when i click notch area (not hover but click) i want the current
deck route to be displayed in the top".

Success: a click on the notch shows the route, a second click hides it, the
route follows the card, the review flow and keys are untouched, and the new
logic is covered by tests written first in `AnkiNotchKit`.

Out of scope: any change to the review flow, a settings-window entry for this,
persisting the toggle across restarts, clicking decks to navigate, audio.

## Decisions (agreed in brainstorming)

1. **Toggle.** A click flips it; it stays on across cards until clicked again.
2. **Placement.** A new slim row (`routeRowHeight`, 22 pt) between the notch
   strip and the card. The card is never covered.
3. **Long paths.** Middle ellipsis: full path if it fits, else
   `Root › … › Leaf`, else `… › Leaf`, else tail truncation of that.
4. **Click target.** Only the notch rect (`PanelGeometry.hotspot`), not the
   black strip beside it. Known risk: on a real notch the pointer is hidden
   there, so the click is blind; check early that it registers.
5. **Persistence.** In memory in `PanelController`: survives panel collapse and
   reopen, resets on relaunch. No `AppSettings` property.

## Behavior

- Hover opens the panel as today (0.15 s dwell). Only the open panel handles
  the click; a click on the closed hotspot (inside the dwell) does nothing.
- Flag on and a card showing (front or back): the row shows the route of
  `CurrentCard.deckName`, dimmed white, centered, ` › ` between components.
- The route follows the card: a new card or a deck change updates the text in
  place.
- `All done`, `Open Anki`, `Anki error` have no deck: the row is hidden and the
  panel keeps its one-line message size. The flag stays on; the row returns
  with the next card.
- Notchless screens: the virtual hotspot behaves the same.
- Keys, hover collapse and the review flow are unchanged.

## Kit side (`AnkiNotchKit`, pure, tests first)

### `DeckRoute` (new)

- `components(of deckName: String) -> [String]`: split on `::`, trim
  whitespace, drop empty components.
- `candidates(for deckName: String) -> [String]`: display strings, longest
  first, joined with ` › `:
  1. all components;
  2. first + `…` + last (only when there are 3 or more components);
  3. `…` + last (only when there are 2 or more components).
  Duplicates removed; a one-component or empty name yields that name (or `[]`
  when empty). The app picks the first that fits the row.

### `PanelGeometry`

- `static let routeRowHeight: CGFloat = 22`.
- `cardSize(contentHeight:showsRoute:)`: adds `routeRowHeight` when true. The
  card area keeps its clamp; the row sits outside it.
- `panelFrame(contentHeight:showsRoute:)`. `stageFrame` is sized for the
  maximum (max content + route row) so the window never changes while the
  shape moves.
- `static func isNotchClick(_ point: CGPoint, hotspot: CGRect) -> Bool`, edges
  included (same convention as `keepsPanelOpen`).
- Existing signatures keep working (`showsRoute` defaults to `false`) so
  current tests stay green.

## App side (`Sources/AnkiNotch`)

- **`PanelController`**
  - State: `showsDeckRoute` (the toggle) and `deckRoute: String?` (set by the
    app). The row is shown when both are set; `routeVisible` is derived.
  - A `routeLabel` in `host`, directly under the notch strip, laid out at its
    final place; it fades in with the same content fade.
  - `layoutContent` offsets `contentView` by the row height when visible.
    Toggling goes through `resize` (same animation path as a card-height
    change: ease-out `resizeDuration`, spring while still opening, no motion
    with Reduce Motion). Card size and the hover check use the route-aware
    height.
  - Click: a local `leftMouseDown` monitor installed with the key monitor and
    removed in `hide()`. It acts only when `event.window === panel` and the
    screen point passes `isNotchClick`, flips the flag, consumes the event.
    Everything else passes through (clicks on the card, the row, the settings
    window).
  - Text fitting: pick the first of `DeckRoute.candidates` whose measured width
    (the label's font) fits the row width minus 2 × 12 pt inset; fall back to
    the last candidate with tail truncation.
- **`AppDelegate.render()`**: passes `card.deckName` for `.front`/`.back` and
  `nil` for message states and keeps the previous value for in-flight phases.
- **Mock** (`ANKINOTCH_MOCK=1`): nested deck names on the sample cards so the
  row and the truncation are visible without touching a real collection.

## Invariants to add to `CLAUDE.md`

- The route row sits outside the content-height clamp and is always counted in
  `stageFrame`; never let it resize the window mid-motion.
- Mouse clicks are handled only through the panel's monitor
  (`event.window === panel`), never on the hotspot window.

## Testing

- Kit: `DeckRoute` (splitting, whitespace, empty components, single and
  two-level names, candidate order and de-duplication) and `PanelGeometry`
  (route-aware size/frames, stage unchanged by the flag, `isNotchClick`
  inside, on the edges, outside).
- Manual with `ANKINOTCH_MOCK=1` only, never the real collection: click on and
  off, route follows the card, long path, message states, collapse/reopen keeps
  the toggle, Reduce Motion, a click on a real notch registers.
- `make test` stays green (46 existing tests plus the new ones).
