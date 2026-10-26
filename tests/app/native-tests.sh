#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$ROOT/build/tests" "$ROOT/build/module-cache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/app/TimeNoteApp/Native/NotificationPlanner.swift" \
  "$ROOT/app/TimeNoteApp/Native/ExportFormatter.swift" \
  "$ROOT/app/TimeNoteApp/Native/ExportDestination.swift" \
  "$ROOT/tests/app/native-tests.swift" -o "$ROOT/build/tests/native-tests"
"$ROOT/build/tests/native-tests"
