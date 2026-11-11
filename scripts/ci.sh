#!/usr/bin/env bash
# Build the app and run the unit-test target on an iOS simulator.
#
# This is the single entry point used by .github/workflows/ios-ci.yml; run it directly to
# reproduce CI locally. Environment overrides:
#   DESTINATION        xcodebuild destination (default: platform=iOS Simulator,name=iPhone 17)
#   WATCH_DESTINATION  watch xcodebuild destination (default: first available Apple Watch)
#   DERIVED_DATA       derived-data path (default: .build/DerivedData)
#   ONLY_TESTING       test target or class filter (default: StrengthAppTests)
#   RESULT_BUNDLE      optional .xcresult path; must not already exist
set -euo pipefail

# xcode-select points at CommandLineTools on this Mac; DEVELOPER_DIR alone fixes xcodebuild.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

cd "$(dirname "$0")/.."

DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
DERIVED_DATA="${DERIVED_DATA:-$PWD/.build/DerivedData}"
ONLY_TESTING="${ONLY_TESTING:-StrengthAppTests}"

if [[ -z "${WATCH_DESTINATION:-}" ]]; then
  watch_udid=$(xcrun simctl list devices available --json | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next(x['udid'] for r in sorted(d, reverse=True) for x in d[r] if x.get('isAvailable') and x['name'].startswith('Apple Watch')))")
  WATCH_DESTINATION="id=$watch_udid"
fi
WATCH_DERIVED_DATA="${WATCH_DERIVED_DATA:-$DERIVED_DATA-watch}"

# A filled-in LiveConfig carries a real server address and a one-use pairing code. CI must never
# pair a device or write to a real database, and a filled copy must never be committed.
config="StrengthAppUITests/LiveConfig.swift"
for expected in 'static let enabled = false' 'static let serverURL = ""' 'static let pairingCode = ""'; do
  if ! grep -qF "$expected" "$config"; then
    echo "error: $config is not at its committed defaults (missing: $expected)" >&2
    echo "restore it with: git checkout -- $config" >&2
    exit 1
  fi
done

echo "Xcode: $(xcodebuild -version | paste -sd ' ' -)"
echo "Watch simulator: $WATCH_DESTINATION"

xcodebuild -project StrengthApp.xcodeproj -scheme StrengthWatch \
  -destination "$WATCH_DESTINATION" -derivedDataPath "$WATCH_DERIVED_DATA" \
  build

xcodebuild -project StrengthApp.xcodeproj -scheme StrengthApp \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA" \
  build

embedded_watch=$(find "$DERIVED_DATA/Build/Products" -type d \
  -path '*/StrengthApp.app/Watch/StrengthWatch.app' -print -quit)
if [[ -z "$embedded_watch" ]]; then
  echo "error: StrengthWatch.app is not embedded at StrengthApp.app/Watch" >&2
  exit 1
fi

args=(test -only-testing:"$ONLY_TESTING" -project StrengthApp.xcodeproj -scheme StrengthApp
      -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA")
if [[ -n "${RESULT_BUNDLE:-}" ]]; then
  args+=(-resultBundlePath "$RESULT_BUNDLE")
fi
xcodebuild "${args[@]}"
