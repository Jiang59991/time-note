#!/usr/bin/env bash
set -euo pipefail

time_note_package_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
time_note_developer_root="$(xcode-select -p)"
time_note_framework_dir="$time_note_developer_root/Library/Developer/Frameworks"
time_note_test_args=(
  test --disable-sandbox --disable-xctest --enable-swift-testing
  --package-path "$time_note_package_root"
  --scratch-path "$time_note_package_root/.build"
  --cache-path "$time_note_package_root/.build/cache"
  --config-path "$time_note_package_root/.build/config"
  --security-path "$time_note_package_root/.build/security"
)

# CLT 6.2 includes Swift Testing but may not expose it through SwiftPM's default paths.
if [[ "$time_note_developer_root" == */CommandLineTools ]] &&
   [[ -d "$time_note_framework_dir/Testing.framework" ]]; then
  time_note_test_args+=(
    -Xswiftc -F -Xswiftc "$time_note_framework_dir"
    -Xlinker -F -Xlinker "$time_note_framework_dir"
    -Xlinker -rpath -Xlinker "$time_note_framework_dir"
  )
  time_note_macro_library="$time_note_developer_root/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
  if [[ -f "$time_note_macro_library" ]]; then
    time_note_test_args+=(-Xswiftc -load-plugin-library -Xswiftc "$time_note_macro_library")
  fi
  # Some CLT distributions ship the overlay binary but omit its module interface.
  # These tests use only base Testing APIs, so the optional overlay is unnecessary.
  if [[ ! -d "$time_note_framework_dir/_Testing_Foundation.framework/Modules" ]]; then
    time_note_test_args+=(-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
  fi
fi

CLANG_MODULE_CACHE_PATH="$time_note_package_root/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$time_note_package_root/.build/module-cache" \
xcrun swift "${time_note_test_args[@]}" "$@"
