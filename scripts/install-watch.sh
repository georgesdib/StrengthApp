#!/usr/bin/env bash
# Install the watch app that Xcode just built for the phone onto the paired Apple Watch.
#
# Why this exists: the iPhone's Watch app hands the embedded bundle over silently. When the
# watch is asleep, off its charger or briefly unreachable, the spinner simply returns to
# "Install" with no reason. This pushes the same embedded bundle directly and prints the real
# result, which is what the phase 6 acceptance run needs.
#
# Environment overrides:
#   WATCH_UDID  device identifier of the watch (default: its hardware UDID when available,
#               otherwise the CoreDevice identifier)
#   CONFIGURATION  Release (default) or Debug
#   APP_PATH    path to StrengthWatch.app (default: newest $CONFIGURATION-iphoneos build)
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-Release}"

if [[ -z "${WATCH_UDID:-}" ]]; then
  list=$(mktemp)
  trap 'rm -f "$list"' EXIT
  xcrun devicectl list devices --json-output "$list" >/dev/null
  WATCH_UDID=$(python3 - "$list" <<'PY'
import json
import sys

devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
for device in devices:
    hardware = device.get("hardwareProperties") or {}
    connection = device.get("connectionProperties") or {}
    if "Watch" not in str(hardware.get("productType", "")):
        continue
    # Simulators report sameMachine; a paired watch on the LAN reports localNetwork.
    if connection.get("transportType") == "localNetwork":
        # devicectl accepts both; prefer the hardware UDID and fall back to the CoreDevice
        # identifier when it is absent.
        print(hardware.get("udid") or device["identifier"])
        break
PY
)
  if [[ -z "$WATCH_UDID" ]]; then
    echo "error: no paired watch on the local network; wake it, keep it on its charger and retry" >&2
    echo "       (or set WATCH_UDID to the watch's hardware UDID)" >&2
    exit 1
  fi
fi

if [[ -z "${APP_PATH:-}" ]]; then
  # Prefer the repo-local device build used by install-iphone.sh, then fall back to Xcode's
  # default DerivedData location.
  for candidate in \
    "$PWD/.build/device/Build/Products/$CONFIGURATION-iphoneos/StrengthApp.app/Watch/StrengthWatch.app" \
    "$HOME"/Library/Developer/Xcode/DerivedData/StrengthApp-*/Build/Products/"$CONFIGURATION"-iphoneos/StrengthApp.app/Watch/StrengthWatch.app; do
    if [[ -d "$candidate" ]]; then
      APP_PATH="$candidate"
      break
    fi
  done
fi
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "error: StrengthWatch.app not found; build the StrengthApp scheme for your iPhone in $CONFIGURATION first" >&2
  exit 1
fi

echo "watch: $WATCH_UDID"
echo "app:   $APP_PATH"

attempt=1
until xcrun devicectl device install app --device "$WATCH_UDID" "$APP_PATH"; do
  if [[ "$attempt" -ge 3 ]]; then
    echo "error: install failed after 3 attempts." >&2
    echo "       Wake the watch, keep it on its charger and on the same network, then retry." >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  echo "install did not reach the watch; retrying in 5 s (attempt $attempt/3)..." >&2
  sleep 5
done
