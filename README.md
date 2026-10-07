# AnkiNotch

A Swift macOS companion that shows Anki review cards in a panel at the notch. Anki remains the scheduler; the app communicates with AnkiConnect on localhost.

This is a personal development repository. Feature work is kept on separate branches.

## Requirements

- macOS 15 or later.
- Swift 6 toolchain.
- Anki Desktop running with AnkiConnect enabled at `http://127.0.0.1:8765` for live reviews.

## Development commands

```sh
make build
make test
make run
```

Tests use a mock Anki client and do not require a running Anki instance. The Makefile supports the Swift Testing framework paths when using macOS Command Line Tools.

`make app` builds and ad-hoc signs an app into `~/Applications`; run it when you intend to replace that installed development build.

## Repository index

- [Sources/AnkiNotch/](Sources/AnkiNotch/): macOS interface and application lifecycle.
- [Sources/AnkiNotchKit/](Sources/AnkiNotchKit/): AnkiConnect client, session state and shared logic.
- [Tests/](Tests/): package tests.
- [scripts/](scripts/): app packaging tools.
- [docs/handoff/](docs/handoff/): development handoff notes.
- [CLAUDE.md](CLAUDE.md): architecture, working conventions and review-safety invariants.

Use a disposable Anki profile for integration testing that answers cards, because those operations change the collection.
