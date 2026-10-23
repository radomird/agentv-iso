#!/bin/bash
#
# The ambient screen and TV off on an installed box (ADR-031). S2.17 with the
# TV session's own idle monitor: a stand-in app, paused, and no input. The
# check sets the time to 45 s with agentv screen idle-after, instead of
# Settings' 10 minutes. Then the TV-off policy, with agentv screen tv off and
# on standing in for the TV's power, which a VM can't switch (S2.8 and S2.9
# are the NUC's).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-idle-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-idle-no-tv"; check "the TV session came up" false; stop_vm; finish; }

# The ambient screen is the home screen's, so setup is done first.
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

ssh_guest "mkdir -p /tmp/agentv-page && cat >/tmp/agentv-page/index.html" <"$(dirname -- "${BASH_SOURCE[0]}")/pages/media.html"
ssh_guest "cd /tmp/agentv-page && (nohup python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &)"
page=http://127.0.0.1:8765/

wait_front() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(front '.front.role // ""') == "$1" ]] && return 0
    sleep 0.5
  done
  return 1
}

# until_status <jq filter> <seconds>: until the filter is true.
until_status() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(jq -r "$1" <<<"$(screen_status)" 2>/dev/null) == "true" ]] && return 0
    sleep 2
  done
  return 1
}

guest "agentv screen open $page" >>"$RUN_DIR/screen.log" 2>&1 || true
check "the stand-in app opens in front" wait_front web 60
guest "agentv screen idle-after 45" >>"$RUN_DIR/screen.log" 2>&1 || true

log "Leaving the TV alone, with the app paused"
check "S2.17 with no input and nothing playing, the ambient screen starts" until_status '.ambient' 150
sleep 2
ocr_screen >"$RUN_DIR/success-idle-ambient.txt" 2>/dev/null || true
capture_console "success-idle-ambient"
check "S2.17 the ambient screen is on the TV (OCR)" grep -Eqi '(mon|tues|wednes|thurs|fri|satur|sun)day' "$RUN_DIR/success-idle-ambient.txt"
check "S2.17 the paused app stays open behind it" test "$(jq -c '[.open[].id]' <<<"$(screen_status)")" = "[\"$page\"]"

guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
check "S2.17 any key goes back to the app" wait_front web 15
check "and the ambient screen is gone" test "$(front '.ambient')" = "false"

# Playing, it stays away.
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
log "Leaving the TV alone, with the app playing"
sleep 100
check "S2.17 something playing keeps the ambient screen away" test "$(front '.ambient')" = "false"

# The TV goes off: what plays pauses at once, then every app closes.
guest "agentv screen idle-after off" >>"$RUN_DIR/screen.log" 2>&1 || true
guest "agentv screen tv off" >>"$RUN_DIR/screen.log" 2>&1 || true
sleep 3
check "S2.8 with the TV off, playback pauses at once" test "$(jq -c '[.open[].paused]' <<<"$(screen_status)")" = "[true]"
log "Waiting out the 2 minutes"
check "S2.8 after 2 minutes every app is closed" until_status '(.open | length) == 0' 150
check "S2.8 and home waits on its ambient screen" test "$(front '.ambient')" = "true"
guest "agentv screen tv on" >>"$RUN_DIR/screen.log" 2>&1 || true
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 3
check "S2.9 when the TV is back, a key brings the home screen" test "$(front '[.front.role, .ambient] | map(tostring) | join(" ")')" = "home false"
screen_shows_home() {
  ocr_screen >"$RUN_DIR/$1.txt" 2>/dev/null || true
  capture_console "$1"
  grep -qi "installed" "$RUN_DIR/$1.txt"
}
check "the home screen's grid is on the TV again (OCR)" screen_shows_home "success-idle-home"

guest "journalctl --user -b --no-pager -u agentv-screen -u agentv-toast" >"$RUN_DIR/idle.log" 2>&1 || true
stop_vm
finish
