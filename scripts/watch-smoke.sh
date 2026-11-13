#!/usr/bin/env bash
# Phase 6.7 simulator smoke test: fetch → start → log → finish on the watch, against a
# disposable server with its own database. Nothing here touches a real server or a real watch.
#
# The watch app is seeded with a watch credential through a Debug-only launch argument, so the
# test does not need a paired iPhone simulator. Contract §17 asks for the simulator path; §18
# says watch UI tests are not a CI gate, so this runs on demand.
#
# Environment overrides:
#   SERVER_DIR       server checkout (default: sibling strength-training-app)
#   WATCH_SIMULATOR  watch simulator name (default: first available Apple Watch)
#   DERIVED_DATA     derived-data path (default: .build/DerivedData)
set -euo pipefail

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

cd "$(dirname "$0")/.."
APP_DIR="$PWD"
SERVER_DIR="${SERVER_DIR:-$APP_DIR/../strength-training-app}"
DIR="${SMOKE_DIR:-/tmp/strengthapp-watch-smoke}"
PORT="${SMOKE_PORT:-8011}"
# The watch simulator does not share the Mac's loopback; reach the server by LAN address.
HOST_IP="${SMOKE_HOST_IP:-$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)}"
BASE="http://$HOST_IP:$PORT"
DERIVED_DATA="${DERIVED_DATA:-$APP_DIR/.build/DerivedData}"

if [[ ! -x "$SERVER_DIR/.venv/bin/strength-coach" ]]; then
  echo "error: server checkout not found at $SERVER_DIR" >&2
  exit 1
fi

rm -rf "$DIR"
mkdir -p "$DIR"

cleanup() {
  if [[ -f "$DIR/server.pid" ]]; then
    kill "$(cat "$DIR/server.pid")" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# A previous run's server must not survive: it would keep the port and a deleted database.
stale=$(lsof -ti "tcp:$PORT" || true)
if [[ -n "$stale" ]]; then
  echo "stopping the previous server on $PORT"
  kill $stale 2>/dev/null || true
  sleep 1
fi

echo "starting disposable server on $BASE"
( cd "$SERVER_DIR" && exec .venv/bin/strength-coach --db "$DIR/coach.db" web --host 0.0.0.0 --port "$PORT" ) > "$DIR/server.log" 2>&1 &
echo $! > "$DIR/server.pid"

for _ in $(seq 1 100); do
  status=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/" || true)
  [[ "$status" == "200" ]] && break
  sleep 0.2
done
if [[ "$status" != "200" ]]; then
  echo "error: server did not start; see $DIR/server.log" >&2
  exit 1
fi

pair_output=$( cd "$SERVER_DIR" && .venv/bin/strength-coach --db "$DIR/coach.db" ios pair --label watch-smoke )
code=$(printf '%s' "$pair_output" | grep -oE '([0-9]{4} ){1}[0-9]{4}' | tr -d ' ' || true)
if [[ -z "$code" ]]; then
  echo "error: no pairing code in: $pair_output" >&2
  exit 1
fi

pair_json=$(curl -s -X POST "$BASE/api/ios/v1/pair" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$code\",\"label\":\"watch-smoke\"}")
phone_token=$(printf '%s' "$pair_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

watch_json=$(curl -s -X POST "$BASE/api/ios/v1/devices/watch" \
  -H "Authorization: Bearer $phone_token" -H 'Content-Type: application/json' -d '{}')
watch_token=$(printf '%s' "$watch_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
watch_id=$(printf '%s' "$watch_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["device"]["device_id"])')

issue_status=$(curl -s -o "$DIR/issue.json" -w '%{http_code}' -X POST "$BASE/api/ios/v1/prescriptions" \
  -H "Authorization: Bearer $watch_token" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen | tr 'A-Z' 'a-z')" \
  -d '{"readiness_ack": true, "execution_target": "watch"}')
if [[ "$issue_status" != "202" ]]; then
  echo "error: plan issue returned $issue_status" >&2
  cat "$DIR/issue.json" >&2
  exit 1
fi

for _ in $(seq 1 150); do
  state=$(curl -s "$BASE/api/ios/v1/plans/current" -H "Authorization: Bearer $watch_token")
  state_status=$(printf '%s' "$state" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
  [[ "$state_status" == "ready" ]] && break
  if [[ "$state_status" == "error" ]]; then
    echo "error: plan build failed: $state" >&2
    exit 1
  fi
  sleep 0.2
done
if [[ "$state_status" != "ready" ]]; then
  echo "error: plan was not ready (last: $state_status)" >&2
  exit 1
fi

if [[ -z "${WATCH_SIMULATOR:-}" ]]; then
  WATCH_SIMULATOR=$(xcrun simctl list devices available --json | python3 -c \
    "import json,sys; d=json.load(sys.stdin)['devices']; print(next(x['name'] for r in sorted(d) for x in d[r] if x.get('isAvailable') and x['name'].startswith('Apple Watch')))")
fi
WATCH_UDID=$(xcrun simctl list devices available --json | WATCH_SIMULATOR="$WATCH_SIMULATOR" python3 -c \
  "import json,os,sys; d=json.load(sys.stdin)['devices']; print(next(x['udid'] for r in sorted(d) for x in d[r] if x.get('isAvailable') and x['name']==os.environ['WATCH_SIMULATOR']))")

echo "watch: $WATCH_SIMULATOR ($WATCH_UDID) · watch device: $watch_id"

# A runner left over from an earlier run makes the next one die before connecting. Shut the
# watch down and let Xcode boot it: a watch booted on its own loses its paired network path.
xcrun simctl shutdown "$WATCH_UDID" 2>/dev/null || true

run_once() {
  TEST_RUNNER_WATCH_SMOKE_URL="$BASE" \
  TEST_RUNNER_WATCH_SMOKE_TOKEN="$watch_token" \
  TEST_RUNNER_WATCH_SMOKE_DEVICE="$watch_id" \
  xcodebuild test \
    -project StrengthApp.xcodeproj \
    -scheme StrengthWatch \
    -destination "id=$WATCH_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:StrengthWatchUITests
}

if ! run_once; then
  echo "retrying once after a runner failure"
  xcrun simctl shutdown "$WATCH_UDID" 2>/dev/null || true
  sleep 3
  run_once
fi
