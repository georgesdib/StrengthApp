#!/usr/bin/env bash
# Build StrengthApp for the paired iPhone and install its embedded watch app on the paired
# Apple Watch.
#
# Why this exists: the iPhone's Watch app hands the embedded bundle over silently. When the
# watch is asleep, off its charger or briefly unreachable, the spinner simply returns to
# "Install" with no reason. This pushes the same embedded bundle directly and prints the real
# result, which is what the phase 6 acceptance run needs.
#
# It builds by default, like install-iphone.sh. It used to install whatever bundle was already
# on disk, so on 2026-11-17 it pushed a build that predated the current sources, reported
# success, and the watch kept running stale code while the change was debugged in the wrong
# place. The build and the staleness guard below are the fix for that trap.
#
# It also refuses to reinstall an identical bundle: every install replaces the watch app, and a
# replacement clears its HealthKit authorisation, so re-pushing unchanged code costs a re-grant
# for nothing. FORCE=1 reinstalls. The bundle carries a build stamp (commit, not clock) so the
# watch and the phone can both name the build actually installed on the wrist.
#
# Usage:
#   ./scripts/install-watch.sh              # Release build + install
#   ./scripts/install-watch.sh --launch     # ... and open it on the watch
#   BUILD=0 ./scripts/install-watch.sh      # install the existing bundle, staleness checked
#   DRY_RUN=1 ./scripts/install-watch.sh    # resolve and print, build and install nothing
#
# Environment overrides:
#   WATCH_UDID     device identifier of the watch (default: its hardware UDID when available,
#                  otherwise the CoreDevice identifier)
#   IPHONE_UDID    destination for the build (default: the paired physical iPhone, else generic)
#   CONFIGURATION  Release (default) or Debug
#   APP_PATH       install this StrengthWatch.app instead of the one embedded in the phone build
#   DERIVED_DATA   build directory (default: .build/device)
#   BUILD=0        skip the build; the bundle must still be newer than the watch sources
#   FORCE=1        install even when the bundle is older than the watch sources, or unchanged
#   LAUNCH=1       launch the watch app after install (same as --launch)
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$PWD/.build/device}"
BUILD="${BUILD:-1}"
FORCE="${FORCE:-0}"
LAUNCH="${LAUNCH:-0}"
DRY_RUN="${DRY_RUN:-0}"

for argument in "$@"; do
  case "$argument" in
    --launch) LAUNCH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-build) BUILD=0 ;;
    -h|--help)
      sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument '$argument' (try --help)" >&2
      exit 2
      ;;
  esac
done

# --- Devices ----------------------------------------------------------------------------------

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
fi

WATCH_APP_RELATIVE="StrengthApp.app/Watch/StrengthWatch.app"

echo "watch:  $WATCH_UDID"
echo "config: $CONFIGURATION"

# --- Build ------------------------------------------------------------------------------------

# The watch stamp identifies the code on the wrist, not the moment of the build: the same tree
# must produce the same bundle, or the skip below can never fire. No time, on purpose.
watch_stamp() {
  local stamp
  stamp=$(git -C "$PWD" rev-parse --short HEAD 2>/dev/null || echo unknown)
  if [[ -n "$(git -C "$PWD" status --porcelain 2>/dev/null)" ]]; then
    stamp="$stamp-dirty"
  fi
  printf '%s' "$stamp"
}

WATCH_STAMP="$(watch_stamp)"

if [[ "$BUILD" == "1" ]]; then
  BUILD_SETTINGS=(STRENGTH_WATCH_STAMP="$WATCH_STAMP")
  if [[ "$CONFIGURATION" == "Release" ]]; then
    BUILD_SETTINGS+=(SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=3)
  fi
  # A generic destination builds the phone app and its embedded watch app without needing the
  # watch awake; a connected iPhone is a better destination when there is one.
  if [[ -n "${IPHONE_UDID:-}" ]]; then
    BUILD_DESTINATION="id=$IPHONE_UDID"
  else
    BUILD_DESTINATION="generic/platform=iOS"
  fi
  echo "building $CONFIGURATION ($BUILD_DESTINATION)..."
  xcodebuild -project StrengthApp.xcodeproj -scheme StrengthApp \
    -configuration "$CONFIGURATION" -destination "$BUILD_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" -allowProvisioningUpdates \
    ${BUILD_SETTINGS[@]+"${BUILD_SETTINGS[@]}"} \
    build
else
  echo "build skipped (BUILD=0)"
fi

# --- Locate the bundle ------------------------------------------------------------------------

if [[ -z "${APP_PATH:-}" ]]; then
  # Prefer the repo-local device build, then fall back to Xcode's DerivedData location.
  for candidate in \
    "$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/$WATCH_APP_RELATIVE" \
    "$PWD/.build/device/Build/Products/$CONFIGURATION-iphoneos/$WATCH_APP_RELATIVE" \
    "$HOME"/Library/Developer/Xcode/DerivedData/StrengthApp-*/Build/Products/"$CONFIGURATION"-iphoneos/"$WATCH_APP_RELATIVE"; do
    if [[ -d "$candidate" ]]; then
      APP_PATH="$candidate"
      break
    fi
  done
fi
if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
  echo "error: StrengthWatch.app not found; build the StrengthApp scheme for your iPhone in $CONFIGURATION first" >&2
  exit 1
fi

# --- Staleness guard --------------------------------------------------------------------------
#
# Only sources that rebuild the watch bundle count: phone-only edits legitimately leave it stale
# and must not block an install. A bundle older than these is the exact failure this guards.

WATCH_BINARY="$APP_PATH/StrengthWatch"
stale_source=""
if [[ -f "$WATCH_BINARY" ]]; then
  # Generated directories are pruned: Xcode rewrites .swiftpm and xcuserdata on every open, so
  # their timestamps say nothing about whether the watch sources changed.
  stale_source=$(find StrengthWatch StrengthCore Support/WatchInfo.plist StrengthApp.xcodeproj \
    \( -name .swiftpm -o -name .build -o -name xcuserdata -o -name DerivedData -o -name .git \) -prune -o \
    -type f \( -name '*.swift' -o -name '*.plist' -o -name '*.xcproj' \) \
    -newer "$WATCH_BINARY" -print -quit 2>/dev/null || true)
fi

built_at=$(date -r "$WATCH_BINARY" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
installed_stamp=$(/usr/libexec/PlistBuddy -c 'Print :StrengthBuildStamp' \
  "$APP_PATH/Info.plist" 2>/dev/null || true)
echo "app:    $APP_PATH"
echo "built:  $built_at"
echo "stamp:  ${installed_stamp:-unknown}"

if [[ "$BUILD" == "1" && "$installed_stamp" != "$WATCH_STAMP" ]]; then
  echo "error: the watch bundle carries stamp '${installed_stamp:-none}', not '$WATCH_STAMP';" >&2
  echo "       it was not rebuilt" >&2
  exit 1
fi

# An install replaces the watch app, and a replacement clears its HealthKit authorisation. Skip
# the byte-identical bundle a rebuild produces, so the athlete pays that re-grant only when the
# watch code actually changed. FORCE=1 reinstalls on purpose (a re-paired watch needs it).
WATCH_DIGEST_FILE="$PWD/.build/installed-watch-${WATCH_UDID}.digest"
bundle_digest() {
  ( cd "$1" && find . -type f \
      ! -path './_CodeSignature/*' \
      ! -name embedded.mobileprovision \
      -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 ) \
    | shasum -a 256 | cut -d' ' -f1
}
digest="$(bundle_digest "$APP_PATH")"
if [[ "$FORCE" != "1" && -f "$WATCH_DIGEST_FILE" && "$(cat "$WATCH_DIGEST_FILE")" == "$digest" ]]; then
  echo "skip:   this exact bundle is already installed on the watch"
  echo "        (FORCE=1 to reinstall; a re-paired or erased watch needs one)"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "dry run: no install performed"
  fi
  exit 0
fi

if [[ -n "$stale_source" && "$FORCE" != "1" ]]; then
  echo "error: the bundled watch app predates the current watch sources." >&2
  echo "       newer than the bundle: $stale_source" >&2
  echo "       Run without BUILD=0 so it rebuilds, or set FORCE=1 to install anyway." >&2
  exit 1
fi
if [[ -n "$stale_source" ]]; then
  echo "warning: installing a bundle older than $stale_source (FORCE=1)" >&2
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "dry run: no install performed"
  exit 0
fi

# --- Install ----------------------------------------------------------------------------------

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

# Only record the digest after the device accepted the bundle: a failed install must not make the
# next run believe this code is already on the wrist.
mkdir -p "$(dirname "$WATCH_DIGEST_FILE")"
printf '%s' "$digest" > "$WATCH_DIGEST_FILE"

if [[ "$LAUNCH" == "1" ]]; then
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || echo "com.georgesdibpersonalteam.StrengthApp.watchkitapp")
  echo "launching $bundle_id..."
  xcrun devicectl device process launch --device "$WATCH_UDID" --terminate-existing "$bundle_id" || true
fi

echo "done: StrengthWatch is installed on the watch"
