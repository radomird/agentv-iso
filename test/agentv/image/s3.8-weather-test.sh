#!/bin/bash
#
# The built-in Weather app on an installed box (ADR-015, ADR-016): with the
# box in Oslo's time zone, the weather tile shows MET Norway's forecast for
# Oslo, and agentv selftest compares the small, medium and large tiles with
# MET's forecast, fetched again, the way the NUC does (S3.8, S3.9). The
# install test's box is in UTC, which has no city, so the tile says where
# to pick one until the time zone changes.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-weather-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-weather-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

tile() {
  ssh_guest "curl -fsS --max-time 10 http://127.0.0.1:3000/api/tile/agentv.weather/$1" 2>/dev/null || true
}

check "in UTC, the weather tile says to pick a city" test "$(tile s | jq -r '.tile.headline.label // ""')" = "no city yet"

ssh_sudo "timedatectl set-timezone Europe/Oslo" >"$RUN_DIR/timezone.log" 2>&1 || true
check "the box is in Oslo's time zone" test "$(ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/weather" | jq -r '.zone + " " + .name')" = "Europe/Oslo oslo"

# MET Norway, from the box: the small tile, then the medium and the large.
until_label() {
  local started=$SECONDS
  while (( SECONDS - started < 60 )); do
    [[ $(tile s | jq -r '.tile.headline.label // ""') == oslo* ]] && return 0
    sleep 3
  done
  return 1
}
check "the weather tile shows Oslo's forecast from MET Norway" until_label
tile s >"$RUN_DIR/weather-s.json"
tile m >"$RUN_DIR/weather-m.json"
tile l >"$RUN_DIR/weather-l.json"
check "the weather tile has a scene and a temperature" \
  jq -e '.tile.headline.icon and (.tile.headline.value | test("^-?[0-9]+°$"))' "$RUN_DIR/weather-s.json"
check "the large tile has seven days" jq -e '(.tile.entries | length) == 7' "$RUN_DIR/weather-l.json"

guest "agentv selftest S3" >"$RUN_DIR/selftest.txt" 2>&1 || true
cat "$RUN_DIR/selftest.txt"
check "S3.8 agentv selftest finds the tile's scene as MET's forecast for now" grep -q "^pass S3.8 the tile shows" "$RUN_DIR/selftest.txt"
check "S3.9 agentv selftest finds the medium and large tiles as MET's days" grep -q "^pass S3.9 the medium and large weather tiles match" "$RUN_DIR/selftest.txt"

# On the TV: the weather large, and the clock beside it.
ssh_guest "curl -fsS -X PUT -H 'Content-Type: application/json' -d '{\"layout\":[{\"id\":\"agentv.weather\",\"x\":0,\"y\":0,\"size\":\"l\"},{\"id\":\"agentv.clock\",\"x\":2,\"y\":0,\"size\":\"m\"},{\"id\":\"apps\",\"x\":3,\"y\":2,\"size\":\"s\"}]}' http://127.0.0.1:3000/api/layout" \
  >"$RUN_DIR/layout.json" 2>&1 || true
sleep 8
ocr_screen >"$RUN_DIR/success-weather-large.txt" 2>/dev/null || true
capture_console "success-weather-large"
check "the TV shows the large weather tile for Oslo (OCR)" grep -qi "oslo" "$RUN_DIR/success-weather-large.txt"
check "the TV shows its seven days (OCR)" grep -qi "7 days" "$RUN_DIR/success-weather-large.txt"

ssh_guest "journalctl -b --no-pager -u agentv-daemon" >"$RUN_DIR/daemon.log" 2>&1 || true
stop_vm
finish
