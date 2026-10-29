#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Time Note.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="$ROOT/build/releases/$VERSION"
ZIP="TimeNote-$VERSION-macOS-universal.zip"
codesign --verify --deep --strict "$APP"
cmp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cmp "$ROOT/NOTICE" "$APP/Contents/Resources/NOTICE.txt"
mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
(cd "$OUT" && shasum -a 256 "$ZIP" > SHA256SUMS)
cp "$ROOT/docs/14-download-guide.md" "$OUT/READ-ME-FIRST.md"
printf 'Packaged %s\n' "$OUT/$ZIP"
