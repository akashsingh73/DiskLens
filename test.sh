#!/bin/bash
# Tests DiskLens using only Apple's free Command Line Tools (no Xcode).
#
#   bash test.sh                     check Swift 6 readiness, then run the tests on a temporary folder tree
#   bash test.sh /Applications ...   also scan these folders and compare their totals with du
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "The Swift compiler isn't installed yet. Install Apple's free Command Line Tools:"
  echo "    xcode-select --install"
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="$(uname -m)-apple-macos14.0"
OUT="build/tests"
mkdir -p "$OUT"

# The app is built in the Swift 5 language mode; this keeps it ready for Swift 6's stricter
# concurrency checks (any warning there fails the run).
echo "Checking that DiskLens compiles cleanly in the Swift 6 language mode…"
if ! xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -wmo \
  -sdk "$SDK" -target "$TARGET" -module-name DiskLens \
  -o "$OUT/DiskLens-swift6" DiskLens/*.swift > "$OUT/swift6.log" 2>&1; then
  cat "$OUT/swift6.log"
  echo
  echo "DiskLens doesn't compile cleanly in Swift 6 mode (full log: $OUT/swift6.log)."
  exit 1
fi

# Everything except the app's entry point, plus the tests (which have their own).
SOURCES=()
for file in DiskLens/*.swift; do
  [[ "$file" == */DiskLensApp.swift ]] || SOURCES+=("$file")
done

echo "Compiling the tests…"
if ! xcrun swiftc -swift-version 5 -parse-as-library \
  -sdk "$SDK" -target "$TARGET" -module-name DiskLens \
  -o "$OUT/DiskLensTests" "${SOURCES[@]}" Tests/*.swift > "$OUT/compile.log" 2>&1; then
  cat "$OUT/compile.log"
  exit 1
fi

"$OUT/DiskLensTests" "$@"
