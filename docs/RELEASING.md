# Publishing a beta

1. Update `VERSION` (for example, `0.1.0-beta.1`) and add release notes under `docs/releases/`. The packaging script puts the numeric portion in `CFBundleShortVersionString` and the full label in `AnkiNotchReleaseVersion`.
2. Run `make test`, `make build`, and `git diff --check`. Smoke-test the panel with sample cards and a disposable Anki profile when testing real grading.
3. Run `make package`. This builds both arm64 and x86_64 and creates `build/AnkiNotch.app`; it does not replace the installed app. Verify with `lipo -archs build/AnkiNotch.app/Contents/MacOS/AnkiNotch` and `codesign --verify --deep --strict build/AnkiNotch.app`.
4. Archive the bundle with `ditto -c -k --sequesterRsrc --keepParent build/AnkiNotch.app build/AnkiNotch-vVERSION-universal.zip` (replace VERSION with the release version). The packaging script includes LICENSE and README in the bundle's Resources. Compute the archive's SHA-256 checksum.
5. Extract the archive to a temporary directory and verify the extracted signature, version, and architectures. Launch the extracted app in mock mode for a smoke check.
6. Merge and push the release commit to main, then publish a GitHub prerelease tagged `vVERSION` at that exact commit, attaching the ZIP and checksum file. Check the assets from an unauthenticated download.

Before changing a private repository to public, review all branch history for secrets, personal data, and private assets. A clean scanner result supplements manual review; it is not a guarantee.

## Signing

The current beta is ad-hoc signed, not notarized. Say so in the README and release notes and link to Apple's [Open Anyway instructions](https://support.apple.com/en-us/102445). Do not tell users to disable Gatekeeper globally.

For future notarized releases, install a Developer ID Application certificate and configure notarization credentials. Sign the bundle with hardened runtime and a secure timestamp, submit the ZIP with `xcrun notarytool`, wait for acceptance, staple the ticket with `xcrun stapler`, then create the final ZIP and verify Gatekeeper assessment. Do not label a release notarized until Apple has accepted it and verification succeeds.
