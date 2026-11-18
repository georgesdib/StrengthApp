#!/usr/bin/env bash
# Build StrengthApp for the paired iPhone and install it with devicectl.
#
# The phone equivalent of scripts/install-watch.sh: build against the device destination, then
# hand the signed bundle to CoreDevice so the result is visible instead of a Xcode spinner.
#
# Every build carries a stamp (UTC time, commit, dirty flag) in its Info.plist. The app sends it
# with the bootstrap request, so the server log names the exact build the installed app is running.
#
# Usage:
#   ./scripts/install-iphone.sh              # Release build + install
#   ./scripts/install-iphone.sh --launch     # ... and launch it
#   REF=<sha|branch> ./scripts/install-iphone.sh   # build a committed ref in a clean worktree
#   CONFIGURATION=Debug ./scripts/install-iphone.sh   # opt into an unoptimised build
#   DRY_RUN=1 ./scripts/install-iphone.sh    # resolve the device and print, build nothing
#
# Environment overrides:
#   IPHONE_UDID    CoreDevice identifier of the iPhone (default: the paired physical iPhone)
#   CONFIGURATION  Release (default) or Debug
#   REF            build this committed ref in a temporary worktree instead of the working tree
#   KEEP_WORKTREE  1 keeps the REF worktree after a successful install
#   APP_PATH       install this .app instead of building
#   BUILD=0        skip the build; requires APP_PATH or a previous build in DERIVED_DATA
#   DERIVED_DATA   build directory (default: .build/device inside the build root)
#   LAUNCH=1       launch after install (same as --launch)
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
LAUNCH="${LAUNCH:-0}"
DRY_RUN="${DRY_RUN:-0}"
BUILD="${BUILD:-1}"
REF="${REF:-}"
KEEP_WORKTREE="${KEEP_WORKTREE:-0}"

for argument in "$@"; do
  case "$argument" in
    --launch) LAUNCH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
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

# A committed ref is built in a throwaway worktree, so a working tree that is mid-edit (or does
# not compile) cannot influence the installed build.
BUILD_ROOT="$REPO_ROOT"
CLEAN_WORKTREE=""
if [[ -n "$REF" ]]; then
  if [[ -n "${APP_PATH:-}" ]]; then
    echo "error: REF and APP_PATH are mutually exclusive" >&2
    exit 2
  fi
  ref_sha=$(git -C "$REPO_ROOT" rev-parse --short "$REF")
  CLEAN_WORKTREE="$(mktemp -d)/strength-iphone-$ref_sha"
  BUILD_ROOT="$CLEAN_WORKTREE"
  if [[ "$DRY_RUN" != "1" ]]; then
    git -C "$REPO_ROOT" worktree add --detach "$BUILD_ROOT" "$REF" >/dev/null
  fi
  echo "ref:    $REF ($ref_sha) -> $BUILD_ROOT"
fi

DERIVED_DATA="${DERIVED_DATA:-$BUILD_ROOT/.build/device}"

if [[ -z "${APP_PATH:-}" ]]; then
  APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/StrengthApp.app"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "app:    $APP_PATH"
  echo "dry run: no build or install performed"
  exit 0
fi

tree_state() {
  # The commit plus the exact working-tree status: any edit during the build changes this.
  git -C "$BUILD_ROOT" rev-parse HEAD
  git -C "$BUILD_ROOT" status --porcelain
}

build_stamp() {
  local dirty=""
  if [[ -n "$(git -C "$BUILD_ROOT" status --porcelain)" ]]; then
    dirty="-dirty"
  fi
  printf '%s-%s%s' "$(date -u +%Y%m%dT%H%M%SZ)" \
    "$(git -C "$BUILD_ROOT" rev-parse --short HEAD)" "$dirty"
}

if [[ "$BUILD" == "1" ]]; then
  STAMP="$(build_stamp)"
  STATE_BEFORE="$(tree_state)"
  BUILD_SETTINGS=("STRENGTH_BUILD_STAMP=$STAMP")
  if [[ "$CONFIGURATION" == "Release" ]]; then
    # Make the optimised build explicit rather than relying on an inherited default.
    BUILD_SETTINGS+=(SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=3)
  fi
  echo "stamp:  $STAMP"
  echo "building $CONFIGURATION for the device..."
  xcodebuild -project "$BUILD_ROOT/StrengthApp.xcodeproj" -scheme StrengthApp \
    -configuration "$CONFIGURATION" -destination "id=$IPHONE_UDID" \
    -derivedDataPath "$DERIVED_DATA" "${BUILD_SETTINGS[@]}" build

  if [[ -z "$CLEAN_WORKTREE" ]]; then
    STATE_AFTER="$(tree_state)"
    if [[ "$STATE_BEFORE" != "$STATE_AFTER" ]]; then
      echo "error: the working tree changed while the build ran, so the product may not match" >&2
      echo "       the tree. Re-run the script, or install a committed ref with REF=<sha>." >&2
      exit 1
    fi
  fi
else
  echo "build skipped (BUILD=0)"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: $APP_PATH not found; run without BUILD=0 or set APP_PATH" >&2
  exit 1
fi

if [[ "$BUILD" != "1" ]]; then
  # A skipped build must still be newer than every source file it claims to contain.
  newer=$(find "$BUILD_ROOT/StrengthApp" "$BUILD_ROOT/StrengthCore/Sources" \
    -name '*.swift' -newer "$APP_PATH" -print -quit 2>/dev/null || true)
  if [[ -n "$newer" ]]; then
    echo "error: $APP_PATH is older than $newer" >&2
    echo "       rebuild, or set APP_PATH to a fresh build" >&2
    exit 1
  fi
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || true)
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist" 2>/dev/null || true)
built_stamp=$(/usr/libexec/PlistBuddy -c 'Print :StrengthBuildStamp' "$APP_PATH/Info.plist" 2>/dev/null || true)
if [[ "$BUILD" == "1" && "$built_stamp" != "$STAMP" ]]; then
  echo "error: the product carries stamp '$built_stamp', not '$STAMP'; it was not rebuilt" >&2
  exit 1
fi

echo "app:    $APP_PATH${version:+ ($version)}"
echo "build:  ${built_stamp:-unknown}"

echo "installing..."
xcrun devicectl device install app --device "$IPHONE_UDID" "$APP_PATH"

if [[ "$LAUNCH" == "1" ]]; then
  if [[ -z "$bundle_id" ]]; then
    echo "error: cannot read CFBundleIdentifier from $APP_PATH/Info.plist" >&2
    exit 1
  fi
  echo "launching $bundle_id..."
  # A locked phone refuses the launch (SBMainWorkspace "Locked"). The install already succeeded,
  # so that is a warning, not a failed install.
  if ! launch_output=$(xcrun devicectl device process launch --device "$IPHONE_UDID" "$bundle_id" 2>&1); then
    printf '%s\n' "$launch_output" >&2
    if grep -qi 'locked\|unlock' <<<"$launch_output"; then
      echo "warning: installed, but the phone was locked so the app could not be launched." >&2
      echo "         unlock the phone and open StrengthApp." >&2
    else
      echo "warning: installed, but the app could not be launched; open it manually." >&2
    fi
  fi
fi

if [[ -n "$CLEAN_WORKTREE" && "$KEEP_WORKTREE" != "1" ]]; then
  git -C "$REPO_ROOT" worktree remove --force "$CLEAN_WORKTREE" >/dev/null 2>&1 || true
fi

echo "done: StrengthApp ${built_stamp:-unknown} is installed on the iPhone"
