#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Time Note.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCHS="${TIME_NOTE_ARCHS:-arm64 x86_64}"
bash "$ROOT/scripts/build-icon.sh"
mkdir -p "$ROOT/build/bin" "$ROOT/build/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in $ARCHS; do
  xcrun swiftc -swift-version 5 -O -parse-as-library -sdk "$SDK" -target "$arch-apple-macosx14.0" \
    -module-cache-path "$ROOT/build/module-cache" \
    -framework AppKit -framework WebKit -framework UserNotifications \
    "$ROOT"/app/TimeNoteApp/Native/*.swift -o "$ROOT/build/bin/TimeNote-$arch"
done
BINARIES=()
for arch in $ARCHS; do BINARIES+=("$ROOT/build/bin/TimeNote-$arch"); done
if [ "${#BINARIES[@]}" -gt 1 ]; then
  xcrun lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/TimeNote"
else
  cp "${BINARIES[0]}" "$APP/Contents/MacOS/TimeNote"
fi
cp "$ROOT/app/TimeNoteApp/Info.plist" "$APP/Contents/Info.plist"
rm -rf "$APP/Contents/Resources/Web"
cp -R "$ROOT/app/TimeNoteApp/Web" "$APP/Contents/Resources/Web"
if [ -d "$ROOT/app/TimeNoteApp/Resources" ]; then cp -R "$ROOT/app/TimeNoteApp/Resources/." "$APP/Contents/Resources/"; fi
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/NOTICE" "$APP/Contents/Resources/NOTICE.txt"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
