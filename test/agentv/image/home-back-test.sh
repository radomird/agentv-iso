#!/bin/bash
#
# Home and Back on an installed box (ADR-031). A stand-in streaming app, a
# page that plays a tone once a key is pressed, opens in the services'
# Chromium. Home pauses it and shows the home screen, and opening it again
# brings the same window back, playing (S2.15). A third app closes the oldest.
# Back stays the app's, holding it for a second goes home, and Home works from
# a keyboard's Home key, a remote's Home button, which is what the phone
# sends, and the mouse's button in the top left corner (S2.16). S2.15's 1 s
# is timed on the NUC; here it's logged.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-home-back-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-home-back-no-tv"; check "the TV session came up" false; stop_vm; finish; }

# The page, served on the box itself.
ssh_guest "mkdir -p /tmp/agentv-page && cat >/tmp/agentv-page/index.html" <"$(dirname -- "${BASH_SOURCE[0]}")/pages/media.html"
ssh_guest "cd /tmp/agentv-page && (nohup python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &)"
page=http://127.0.0.1:8765/

# wait_front <role> <seconds>: until <role> is in front. Prints the seconds.
wait_front() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    if [[ $(front '.front.role // ""') == "$1" ]]; then
      echo $(( SECONDS - started ))
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# Whether the overlay's corner, the mouse's Home, is on the screen.
corner_ready() {
  guest_hyprctl "-j layers" 2>/dev/null | jq -e '[.. | objects | select(.namespace? == "agentv-corner")] | length > 0' >/dev/null 2>&1
}

# wait_corner <yes|no> <seconds>
wait_corner() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    if corner_ready; then [[ $1 == "yes" ]] && return 0; else [[ $1 == "no" ]] && return 0; fi
    sleep 0.5
  done
  return 1
}

# A jq filter on the apps open, from the screen daemon.
opened() {
  jq -c "$1" <<<"$(screen_status)" 2>/dev/null || true
}

guest "agentv screen open $page" >>"$RUN_DIR/screen.log" 2>&1 || true
check "the stand-in app opens in front" wait_front web 60
sleep 3
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 2
capture_console "success-home-back-app"

# Home, from a keyboard's Home key.
started=$(date +%s%N)
guest "agentv input key home-key" >>"$RUN_DIR/input.log" 2>&1 || true
check "S2.16 a keyboard's Home key shows the home screen" wait_front home 10
log "Home was in front $(( ($(date +%s%N) - started) / 1000000 )) ms after the key was sent"
check "S2.15 Home paused the app and kept it open behind home" \
  test "$(opened "[.open[] | {id, paused}]")" = "[{\"id\":\"$page\",\"paused\":true}]"

# The same app again: the same window, playing where it was.
guest "agentv screen open $page" >>"$RUN_DIR/screen.log" 2>&1 || true
check "S2.15 opening it again brings it back" wait_front web 10
check "S2.15 and plays it again" test "$(opened "[.open[] | {paused, front}]")" = '[{"paused":false,"front":true}]'
check "the same window came back, not a new one" \
  test "$(opened '[.windows[] | select(.role == "web")] | length')" = "1"

# Back is the app's: a tap stays in it, a second's hold goes home.
guest "agentv input key back" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 3
check "S2.16 Back reaches the app in front, which stays" test "$(front '.front.role')" = "web"
guest "agentv input hold back 1.4" >>"$RUN_DIR/input.log" 2>&1 || true
check "S2.16 holding Back for a second goes home" wait_front home 10

# A remote's Home button, which is also the phone's.
guest "agentv screen open $page" >>"$RUN_DIR/screen.log" 2>&1 || true
wait_front web 10 >/dev/null || true
guest "agentv input key home" >>"$RUN_DIR/input.log" 2>&1 || true
check "S2.16 a remote's Home button, the phone's too, shows the home screen" wait_front home 10

# The mouse: pushed into the top left corner, the pointer shows Home there,
# and a click on it goes home. On the home screen the corner is the
# launcher's own.
check "the corner's Home button isn't there on the home screen" wait_corner no 10
guest "agentv screen open $page" >>"$RUN_DIR/screen.log" 2>&1 || true
wait_front web 10 >/dev/null || true
check "the corner's Home button is ready while an app is in front" wait_corner yes 10
guest "agentv input move -4000 -4000" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 1
capture_console "success-home-back-corner"
corner_text=""
if [[ -s $RUN_DIR/success-home-back-corner.png ]]; then
  corner_text=$(magick "$RUN_DIR/success-home-back-corner.png" -gravity northwest -crop 25%x20%+0+0 +repage -colorspace gray -resize 300% png:- 2>/dev/null |
    tesseract - - --psm 6 2>/dev/null || true)
fi
check "S2.16 the pointer in the top left corner shows Home there (OCR: ${corner_text//$'\n'/ })" grep -qi "home" <<<"$corner_text"
guest "agentv input click" >>"$RUN_DIR/input.log" 2>&1 || true
check "S2.16 a click on the corner's Home shows the home screen" wait_front home 10
check "S2.15 and the app stays open behind it, paused" test "$(opened '[.open[] | select(.front == false) | .paused] | all')" = "true"
check "the corner's Home button goes once home is in front" wait_corner no 10

# Two more apps: the first goes.
for n in 2 3; do
  guest "agentv screen open ${page}?app=$n" >>"$RUN_DIR/screen.log" 2>&1 || true
  wait_front web 30 >/dev/null || true
  sleep 2
  guest "agentv input key home-key" >>"$RUN_DIR/input.log" 2>&1 || true
  wait_front home 10 >/dev/null || true
done
sleep 2
check "S2.15 a third app closes the oldest, and two stay open" \
  test "$(opened '[.open[].id]')" = "[\"${page}?app=2\",\"${page}?app=3\"]"
check "the oldest app's window is gone" test "$(opened '[.windows[] | select(.role == "web")] | length')" = "2"
capture_console "success-home-back-home"

guest "journalctl --user -b --no-pager -u agentv-screen -u agentv-input" >"$RUN_DIR/home-back.log" 2>&1 || true
stop_vm
finish
