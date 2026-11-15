#!/usr/bin/env bash
# Build StrengthApp for the paired iPhone and install it with devicectl.
#
# The phone equivalent of scripts/install-watch.sh: build against the device destination, then
# hand the signed bundle to CoreDevice so the result is visible instead of a Xcode spinner.
#
# Usage:
#   ./scripts/install-iphone.sh              # Debug build + install
#   ./scripts/install-iphone.sh --launch     # ... and launch it
#   CONFIGURATION=Release ./scripts/install-iphone.sh
#   DRY_RUN=1 ./scripts/install-iphone.sh    # resolve the device and print, build nothing
#
# Environment overrides:
#   IPHONE_UDID    CoreDevice identifier of the iPhone (default: the paired physical iPhone)
#   CONFIGURATION  Debug (default) or Release
#   APP_PATH       install this .app instead of building
#   BUILD=0        skip the build; requires APP_PATH or a previous build in DERIVED_DATA
#   DERIVED_DATA   build directory (default: .build/device)
#   LAUNCH=1       launch after install (same as --launch)
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-$PWD/.build/device}"
LAUNCH="${LAUNCH:-0}"
DRY_RUN="${DRY_RUN:-0}"
BUILD="${BUILD:-1}"

for argument in "$@"; do
  case "$argument" in
    --launch) LAUNCH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument '$argument' (try --help)" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${IPHONE_UDID:-}" ]]; then
  list=$(mktemp)
  trap 'rm -f "$list"' EXIT
  xcrun devicectl list devices --json-output "$list" >/dev/null
  IPHONE_UDID=$(python3 - "$list" <<'PY'
import json
import sys

devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
for device in devices:
    hardware = device.get("hardwareProperties") or {}
    properties = device.get("deviceProperties") or {}
    connection = device.get("connectionProperties") or {}
    if not str(hardware.get("productType", "")).startswith("iPhone"):
        continue
    if properties.get("provider"):
        continue  # simulator
    if connection.get("pairingState") != "paired":
        continue
    if connection.get("transportType") == "sameMachine":
        continue
    print(device["identifier"])
    break
PY
)
  if [[ -z "$IPHONE_UDID" ]]; then
    echo "error: no paired physical iPhone; connect it by USB or the same network," >&2
    echo "       unlock it, trust this Mac, and retry (or set IPHONE_UDID)" >&2
    exit 1
  fi
fi

echo "iphone: $IPHONE_UDID"
echo "config: $CONFIGURATION"

if [[ -z "${APP_PATH:-}" ]]; then
  APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/StrengthApp.app"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "app:    $APP_PATH"
  echo "dry run: no build or install performed"
  exit 0
fi

if [[ "$BUILD" == "1" ]]; then
  echo "building $CONFIGURATION for the device..."
  xcodebuild -project StrengthApp.xcodeproj -scheme StrengthApp \
    -configuration "$CONFIGURATION" -destination "id=$IPHONE_UDID" \
    -derivedDataPath "$DERIVED_DATA" build
else
  echo "build skipped (BUILD=0)"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: $APP_PATH not found; run without BUILD=0 or set APP_PATH" >&2
  exit 1
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || true)
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist" 2>/dev/null || true)
echo "app:    $APP_PATH${version:+ ($version)}"

echo "installing..."
xcrun devicectl device install app --device "$IPHONE_UDID" "$APP_PATH"

if [[ "$LAUNCH" == "1" ]]; then
  if [[ -z "$bundle_id" ]]; then
    echo "error: cannot read CFBundleIdentifier from $APP_PATH" >&2
    exit 1
  fi
  echo "launching $bundle_id..."
  xcrun devicectl device process launch --device "$IPHONE_UDID" "$bundle_id"
fi

echo "done: StrengthApp is installed on the iPhone"
