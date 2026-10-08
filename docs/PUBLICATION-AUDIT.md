# First-publication audit

Performed on 2026-10-08 before publishing v0.1.0-beta.1.

- Fetched origin and examined all reachable branches/history: 34 commits and 146 historical text blobs at the pre-release baseline.
- Gitleaks 8.30.1, downloaded from its official release and checksum-verified, scanned all refs with redacted output: no leaks detected.
- Reviewed tracked source, tests, configuration, design plans, and handoff notes. No Anki collections, exported decks, signing credentials, environment files, private screenshots, or user card content are tracked. Historical filename/path/email checks found no private assets or absolute home paths in blob contents.
- The development documents describe historical designs and are not current user instructions. README is the current installation and usage guide.
- The project uses Apple system frameworks and no external Swift package dependencies. Anki and AnkiConnect are separate installations; they are not bundled. Demo imagery uses synthetic sample cards and an isolated backdrop.
- Added the MIT license, contributor guidance, AI coding-assistance disclosure, setup documentation, privacy details, limitations, and public-beta release notes.
- No Developer ID signing identity is installed on the release machine. The first beta is explicitly ad-hoc signed and not notarized. The download includes arm64 and x86_64 slices; Intel hardware testing remains outstanding.

This is a bounded pre-publication review, not a guarantee that all possible secrets or defects have been ruled out. Future contributions and releases need their own review.
