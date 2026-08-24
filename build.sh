#!/bin/bash
# Build Verbatim.app into dist/. Ad-hoc signed; local use only.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=dist/Verbatim.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/Verbatim "$APP/Contents/MacOS/Verbatim"

# A stable signing identity keeps macOS permission grants (Accessibility,
# Microphone) valid across rebuilds; ad-hoc signatures reset them every build.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -oE '"(Developer ID Application|Apple Development)[^"]*"' | tr -d '"')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed as: ${IDENTITY:-ad-hoc}"

echo "Built $APP"
