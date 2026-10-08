#!/bin/sh
# Assemble an ad-hoc signed app without Xcode. Not notarized.
# Default: native build, installed to ~/Applications.
# --package-only: leave the bundle in build/ without installing.
# --universal: build Apple silicon and Intel slices.
set -eu
cd "$(dirname "$0")/.."

INSTALL=1
UNIVERSAL=0
for argument in "$@"; do
    case "$argument" in
        --package-only) INSTALL=0 ;;
        --universal) UNIVERSAL=1 ;;
        *) echo "Unknown option: $argument" >&2; exit 2 ;;
    esac
done
RELEASE_VERSION="$(cat VERSION)"
if ! printf '%s\n' "$RELEASE_VERSION" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+(\.[a-zA-Z0-9]+)*)?$'; then
    echo "Invalid VERSION" >&2
    exit 2
fi
APP_VERSION="${RELEASE_VERSION%%-*}"

if [ "$UNIVERSAL" = 1 ]; then
    swift build -c release --scratch-path .build/universal --triple arm64-apple-macosx15.0
    ARM_BIN="$(swift build -c release --scratch-path .build/universal --triple arm64-apple-macosx15.0 --show-bin-path)/AnkiNotch"
    swift build -c release --scratch-path .build/universal --triple x86_64-apple-macosx15.0
    INTEL_BIN="$(swift build -c release --scratch-path .build/universal --triple x86_64-apple-macosx15.0 --show-bin-path)/AnkiNotch"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/AnkiNotch"
fi

APP=build/AnkiNotch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "$UNIVERSAL" = 1 ]; then
    lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP/Contents/MacOS/AnkiNotch"
else
    cp "$BIN" "$APP/Contents/MacOS/AnkiNotch"
fi
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp README.md CONTRIBUTING.md CLAUDE.md "$APP/Contents/Resources/"
cp -R docs "$APP/Contents/Resources/docs"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.ankinotch.app</string>
  <key>CFBundleName</key><string>AnkiNotch</string>
  <key>CFBundleDisplayName</key><string>AnkiNotch</string>
  <key>CFBundleExecutable</key><string>AnkiNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AnkiNotchReleaseVersion string $RELEASE_VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

if [ "$INSTALL" = 0 ]; then
    echo "Packaged $APP ($RELEASE_VERSION)"
    exit 0
fi

DEST="$HOME/Applications/AnkiNotch.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "Installed $DEST"
