#!/bin/sh
# Foundation-only production rules; works wherever swiftc + Foundation are installed.
# Off Apple platforms it also runs TextCheckerCorrectionProvider against stand-in UIKit and os
# modules with small word lists (tests/linux/), since Apple's UIKit can't be imported there.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -parse-as-library \
  "$ROOT/plugins/keyboard-extension/ios/KeyboardAutocorrection.swift" \
  "$ROOT/plugins/keyboard-extension/ios/KeyboardFrequencyList.swift" \
  "$ROOT/plugins/keyboard-extension/ios/KeyboardContextModel.swift" \
  "$ROOT/plugins/keyboard-extension/tests/KeyboardAutocorrectionTests.swift" \
  -o "$OUT/keyboard-autocorrection-tests"
"$OUT/keyboard-autocorrection-tests"

if [ "$(uname)" != Darwin ]; then
  PLUGIN="$ROOT/plugins/keyboard-extension"
  # A module named `os` makes swiftc warn about os_log sections; only that warning is dropped.
  quiet() {
    "$@" 2>"$OUT/stderr" || { cat "$OUT/stderr" >&2; return 1; }
    grep -v -e osLogStringSectionName -e '^\[#OSLog\]' -e '^$' "$OUT/stderr" >&2 || true
  }
  for module in UIKit os; do
    quiet swiftc -swift-version 5 -parse-as-library -emit-library -emit-module -module-name "$module" \
      "$PLUGIN/tests/linux/$module.swift" -o "$OUT/lib$module.so" \
      -emit-module-path "$OUT/$module.swiftmodule"
  done
  quiet swiftc -swift-version 5 -parse-as-library -I "$OUT" -L "$OUT" -lUIKit -los \
    -Xlinker -rpath -Xlinker "$OUT" \
    "$PLUGIN/ios/KeyboardAutocorrection.swift" "$PLUGIN/ios/KeyboardFrequencyList.swift" \
    "$PLUGIN/ios/KeyboardContextModel.swift" \
    "$PLUGIN/ios/TextCheckerCorrectionProvider.swift" "$PLUGIN/tests/TextCheckerCorrectionProviderTests.swift" \
    -o "$OUT/keyboard-provider-tests"
  "$OUT/keyboard-provider-tests"
fi
