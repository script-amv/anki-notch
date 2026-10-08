# Contributing

Bug reports, compatibility reports, and focused pull requests are welcome. For a larger change, open an issue first so we can agree on its scope.

Include your macOS version, Anki/AnkiConnect versions, Mac chip, reproduction steps, and expected behavior. Use sample or redacted cards; never attach your collection, credentials, or private study material.

Use Swift 6 on macOS 15 or later. Run `make test` and `make build` before submitting a code change. UI changes also need a manual check with `ANKINOTCH_MOCK=1 make run`. Read [CLAUDE.md](CLAUDE.md) for review and animation invariants; pure logic belongs in `AnkiNotchKit` and UI code in `AnkiNotch`.

Integration checks that grade cards must use a disposable Anki profile. Grading changes the collection. Changes must keep Anki as the only scheduler and must never grade a card the user has not seen.

By contributing, you agree to license your contribution under this repository's MIT license. Disclose AI coding assistance in your pull request when used.
