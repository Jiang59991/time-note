#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_BUILD="$ROOT/build/icons"
ICONSET="$ICON_BUILD/TimeNote.iconset"
mkdir -p "$ICONSET" "$ROOT/build/module-cache"
xcrun swiftc -module-cache-path "$ROOT/build/module-cache" "$ROOT/scripts/make-icon.swift" -o "$ICON_BUILD/make-icon"
"$ICON_BUILD/make-icon" "$ROOT/design/assets/time-note-logo-v3.png" "$ICON_BUILD/TimeNote-1024.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_BUILD/TimeNote-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$ICON_BUILD/TimeNote-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/app/TimeNoteApp/Resources/TimeNote.icns"
