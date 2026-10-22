#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SessionMonitor"
BUNDLE_ID="com.felix.sessionmonitor"
MIN_SYSTEM_VERSION="14.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--build-only) ;;
  *) echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
if [[ "$MODE" != "--build-only" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
# SwiftPM's Swift Build backend currently stamps the deployment target as the
# linked SDK version. That opts AppKit into legacy appearance. The native backend
# correctly records the selected SDK while preserving the macOS 14 minimum.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# Remap compiler source paths before packaging: bundles must not embed a developer's
# personal checkout in #filePath strings or debug metadata. Dependencies are under ROOT_DIR.
BUILD_FLAGS=(-Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=/src/SessionMonitor"
             -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=/src/SessionMonitor"
             -Xcc "-fdebug-prefix-map=$ROOT_DIR=/src/SessionMonitor"
             -Xcc "-ffile-prefix-map=$ROOT_DIR=/src/SessionMonitor")
swift build --build-system native --sdk "$SDK_PATH" "${BUILD_FLAGS[@]}" --product "$APP_NAME"
BUILD_BINARY="$(swift build --build-system native --sdk "$SDK_PATH" --show-bin-path)/$APP_NAME"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
LINKED_SDK_VERSION="$(xcrun vtool -show-build "$APP_BINARY" | awk '$1 == "sdk" { print $2; exit }')"
if [[ "$LINKED_SDK_VERSION" != "$SDK_VERSION" ]]; then
  echo "Linked SDK $LINKED_SDK_VERSION does not match selected SDK $SDK_VERSION; refusing to package compatibility-styled controls." >&2
  exit 1
fi

cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Session Monitor</string>
  <key>CFBundleDisplayName</key><string>Session Monitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5.1</string>
  <key>CFBundleVersion</key><string>7</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

mkdir -p "$APP_CONTENTS/Resources/Acknowledgements"
install -m 644 "$ROOT_DIR/.build/checkouts/swift-markdown/LICENSE.txt" "$APP_CONTENTS/Resources/Acknowledgements/Swift-Markdown.txt"
install -m 644 "$ROOT_DIR/.build/checkouts/swift-markdown/NOTICE.txt" "$APP_CONTENTS/Resources/Acknowledgements/Swift-Markdown-Notice.txt"
install -m 644 "$ROOT_DIR/.build/checkouts/swift-cmark/COPYING" "$APP_CONTENTS/Resources/Acknowledgements/cmark.txt"
install -m 644 "$ROOT_DIR/DEPENDENCIES.md" "$APP_CONTENTS/Resources/Acknowledgements/Dependencies.md"
if [[ -f "$ROOT_DIR/LICENSE" ]]; then
  install -m 644 "$ROOT_DIR/LICENSE" "$APP_CONTENTS/Resources/Acknowledgements/SessionMonitor.txt"
fi

/usr/bin/codesign --force --sign - "$APP_BUNDLE" >/dev/null
open_app() { /usr/bin/open -n "$APP_BUNDLE"; }
case "$MODE" in
  --build-only) echo "Built $APP_BUNDLE" ;;
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
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
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    echo "Session Monitor launched successfully."
    ;;
esac
