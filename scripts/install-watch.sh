#!/usr/bin/env bash
# Install the watch app that Xcode just built for the phone onto the paired Apple Watch.
#
# Why this exists: the iPhone's Watch app hands the embedded bundle over silently. When the
# watch is asleep, off its charger or briefly unreachable, the spinner simply returns to
# "Install" with no reason. This pushes the same embedded bundle directly and prints the real
# result, which is what the phase 6 acceptance run needs.
#
# Environment overrides:
#   WATCH_UDID  CoreDevice identifier of the watch (default: the paired watch on the local network)
#   APP_PATH    path to StrengthWatch.app (default: newest Debug-iphoneos build)
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

cd "$(dirname "$0")/.."

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
        print(device["identifier"])
        break
PY
)
  if [[ -z "$WATCH_UDID" ]]; then
    echo "error: no paired watch on the local network; wake it, keep it on its charger and retry" >&2
    exit 1
  fi
fi

if [[ -z "${APP_PATH:-}" ]]; then
  APP_PATH=$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/StrengthApp-*/Build/Products/Debug-iphoneos/StrengthApp.app/Watch/StrengthWatch.app 2>/dev/null | head -1 || true)
fi
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "error: StrengthWatch.app not found; build the StrengthApp scheme for your iPhone first" >&2
  exit 1
fi

echo "watch: $WATCH_UDID"
echo "app:   $APP_PATH"
xcrun devicectl device install app --device "$WATCH_UDID" "$APP_PATH"
