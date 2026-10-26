#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
task_build="$task_root/build/store-tests"
mkdir -p "$task_build/module-cache"
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$task_build/module-cache" \
  "$task_root/app/TimeNoteApp/Native/StoreEngine.swift" \
  "$task_root/tests/app/store-tests.swift" \
  -o "$task_build/store-tests"
"$task_build/store-tests"
