#!/bin/sh
# The LibreOffice autocorrection benchmark (plugins/keyboard-extension/tests/benchmark/) through the
# production keyboard rules and TextCheckerCorrectionProvider.
#
#   sh scripts/benchmark-keyboard-autocorrection.sh [--frequency] [--rev <commit>] [--details]
#     [--alphabetical-completions] [--lexicon-words <n>]
#   sh scripts/benchmark-keyboard-autocorrection.sh --measure-lists   (open time, lookups, memory)
#   sh scripts/benchmark-keyboard-autocorrection.sh --sentences [--split dev|test] [--pairs <n>]
#     [--weights 0,0.1,…] [--caps 8] [--noisy-previous] [--details]   (Linux: typos in Wikipedia sentences, with and
#     without the word-pair context; builds the context lists and the sentences first)
#   sh scripts/benchmark-keyboard-autocorrection.sh --with-context   (LibreOffice cases with context)
#
# macOS: Mac Catalyst with Apple's UITextChecker (needs Xcode; not run from Linux).
# Linux: stand-in UIKit/os modules with AOSP word lists as dictionaries, a simulation of the rules
# (tests/linux/). The word lists are downloaded once to $AOSP_WORDLISTS (pinned, checksummed).
# --frequency also builds the frequency lists and compares with and without them, case by case.
# --rev runs the rules and provider of an earlier commit instead (no frequency lists).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/plugins/keyboard-extension"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
FREQUENCY=""
MEASURE=""
REV=""
DETAILS=""
ALPHABETICAL=""
LEXICON_WORDS=""
SENTENCES=""
WITH_CONTEXT=""
NOISY=""
SPLIT=dev
PAIRS=300000
WEIGHTS=""
CAPS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --frequency) FREQUENCY=1 ;;
    --measure-lists) MEASURE=1 ;;
    --details) DETAILS=1 ;;
    --alphabetical-completions) ALPHABETICAL=1 ;;
    --rev) [ $# -ge 2 ] || { echo "--rev needs a commit" >&2; exit 2; }; REV="$2"; shift ;;
    --lexicon-words) [ $# -ge 2 ] || { echo "--lexicon-words needs a number" >&2; exit 2; }; LEXICON_WORDS="$2"; shift ;;
    --sentences) SENTENCES=1 ;;
    --with-context) WITH_CONTEXT=1 ;;
    --noisy-previous) NOISY=1 ;;
    --split) [ $# -ge 2 ] || { echo "--split needs dev or test" >&2; exit 2; }; SPLIT="$2"; shift ;;
    --pairs) [ $# -ge 2 ] || { echo "--pairs needs a number" >&2; exit 2; }; PAIRS="$2"; shift ;;
    --weights) [ $# -ge 2 ] || { echo "--weights needs a list" >&2; exit 2; }; WEIGHTS="$2"; shift ;;
    --caps) [ $# -ge 2 ] || { echo "--caps needs a list" >&2; exit 2; }; CAPS="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$REV" ] && { [ -n "$FREQUENCY" ] || [ -n "$MEASURE" ] || [ -n "$SENTENCES" ] || [ -n "$WITH_CONTEXT" ]; }; then
  echo "--rev runs a provider without lists; it doesn't combine with --frequency, --measure-lists or --sentences" >&2
  exit 2
fi
if [ -n "$SENTENCES" ] && [ "$(uname)" = Darwin ]; then
  echo "--sentences runs on Linux only (its stand-in dictionaries pick the words to mistype)" >&2
  exit 2
fi

RULES="$PLUGIN/ios/KeyboardAutocorrection.swift"
PROVIDER="$PLUGIN/ios/TextCheckerCorrectionProvider.swift"
BASELINE=""
if [ -n "$REV" ]; then
  mkdir -p "$OUT/rev"
  for file in KeyboardAutocorrection.swift TextCheckerCorrectionProvider.swift; do
    git -C "$ROOT" show "$REV:./plugins/keyboard-extension/ios/$file" > "$OUT/rev/$file"
  done
  RULES="$OUT/rev/KeyboardAutocorrection.swift"
  PROVIDER="$OUT/rev/TextCheckerCorrectionProvider.swift"
  BASELINE="-DBASELINE"
  echo "Rules and provider at $(git -C "$ROOT" rev-parse --short "$REV")"
fi
# The sources, each its own argument, so paths may contain spaces.
compile() {
  if [ -n "$BASELINE" ]; then set -- "$@" "$BASELINE"; fi
  "$@" "$RULES" "$PLUGIN/ios/KeyboardFrequencyList.swift" "$PLUGIN/ios/KeyboardContextModel.swift" "$PROVIDER" \
    "$PLUGIN/tests/KeyboardAutocorrectionBenchmark.swift" -o "$OUT/benchmark"
}

LEXICONS=""
if [ "$(uname)" = Darwin ]; then
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
  # Matches IPHONEOS_DEPLOYMENT_TARGET in withKeyboardExtension.js.
  compile xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O -sdk "$SDK" \
    -target "$(uname -m)-apple-ios15.1-macabi" \
    -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks"
else
  LEXICONS="${AOSP_WORDLISTS:-$HOME/.cache/openwhispr/aosp-wordlists}"
  node "$ROOT/scripts/build-keyboard-frequency-lists.mjs" --fetch-sources "$LEXICONS" >/dev/null
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
  quiet compile swiftc -swift-version 5 -parse-as-library -O -I "$OUT" -L "$OUT" -lUIKit -los \
    -Xlinker -rpath -Xlinker "$OUT"
fi

if [ -n "$FREQUENCY" ] || [ -n "$MEASURE" ]; then
  if [ -n "$LEXICONS" ]; then
    node "$ROOT/scripts/build-keyboard-frequency-lists.mjs" --source "$LEXICONS" --out "$OUT/lists"
  else
    node "$ROOT/scripts/build-keyboard-frequency-lists.mjs" --out "$OUT/lists"
  fi
fi
if [ -n "$MEASURE" ]; then
  "$OUT/benchmark" --measure-lists "$OUT/lists"
  exit 0
fi

if [ -n "$SENTENCES" ] || [ -n "$WITH_CONTEXT" ]; then
  node "$ROOT/scripts/build-keyboard-context-lists.mjs" --out "$OUT/context" --pairs "$PAIRS"
fi
if [ -n "$SENTENCES" ]; then
  node "$ROOT/scripts/build-keyboard-context-sentences.mjs" >/dev/null
fi

set -- --fixtures "$PLUGIN/tests/benchmark"
if [ -n "$LEXICONS" ]; then set -- "$@" --lexicons "$LEXICONS"; fi
if [ -n "$FREQUENCY" ]; then set -- "$@" --frequency "$OUT/lists"; fi
if [ -n "$DETAILS" ]; then set -- "$@" --details; fi
if [ -n "$ALPHABETICAL" ]; then set -- "$@" --alphabetical-completions; fi
if [ -n "$LEXICON_WORDS" ]; then set -- "$@" --lexicon-words "$LEXICON_WORDS"; fi
if [ -n "$WITH_CONTEXT" ] && [ -z "$SENTENCES" ]; then set -- "$@" --context "$OUT/context"; fi
if [ -n "$SENTENCES" ]; then
  set -- "$@" --sentences "${CONTEXT_SENTENCES:-$HOME/.cache/openwhispr/context-sentences}" \
    --context "$OUT/context" --split "$SPLIT"
  if [ -n "$WEIGHTS" ]; then set -- "$@" --weights "$WEIGHTS"; fi
  if [ -n "$CAPS" ]; then set -- "$@" --caps "$CAPS"; fi
  if [ -n "$NOISY" ]; then set -- "$@" --noisy-previous; fi
fi
"$OUT/benchmark" "$@"
