#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Kestra"
BUNDLE_ID="com.kiannest.kestra"
MIN_SYSTEM_VERSION="26.0"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
APP_VERSION="${APP_VERSION:-1.0}"
APP_BUILD_VERSION="${APP_BUILD_VERSION:-1}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
SPARKLE_ENABLED="${SPARKLE_ENABLED:-false}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/qyuja/Kestra/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-YRRedh8vMkmanf6BJCLs0dLIYjc1fM6gieABQn/FSbY=}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --configuration "$BUILD_CONFIGURATION"
BUILD_BIN_DIR="$(swift build --configuration "$BUILD_CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
BUILD_RESOURCE_BUNDLE="$BUILD_BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp -R "$BUILD_RESOURCE_BUNDLE" "$APP_RESOURCES/"
ditto "$BUILD_BIN_DIR/Sparkle.framework" "$APP_FRAMEWORKS/Sparkle.framework"
install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_BINARY"

SPARKLE_PLIST=""
if [[ "$SPARKLE_ENABLED" == "true" ]]; then
  SPARKLE_PLIST=$(cat <<PLIST
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
PLIST
)
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Kestra</string>
  <key>CFBundleDisplayName</key>
  <string>Kestra</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
$SPARKLE_PLIST
</dict>
</plist>
PLIST

# SwiftPM signs the standalone executable before the macOS app bundle exists.
# Re-sign the assembled bundle so its Info.plist and Contents/Resources are
# sealed together. A Developer ID identity can be supplied by CI; the default
# ad-hoc signature keeps local builds structurally valid without pretending
# they are notarized releases.
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP_BUNDLE"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  package)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [package|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
