#!/bin/bash
# Build Verbatim.app into dist/. Ad-hoc signed; local use only.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=dist/Verbatim.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp .build/release/Verbatim "$APP/Contents/MacOS/Verbatim"
codesign --force --sign - "$APP"

echo "Built $APP"
