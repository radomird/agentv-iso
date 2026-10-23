#!/bin/bash
#
# S1.6: no window takes the screen from the TV unless the daemon puts it in
# front (ADR-031). Tried here: a new window, one that opens full screen, one
# that's focused from outside, Omarchy's terminal key, and a crash and
# restart of the home screen. The update is tried in s0.5-update-test.sh,
# which updates the box while the TV is on.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-S1.6-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-S1.6-no-tv"; check "the TV session came up" false; stop_vm; finish; }

home=$(front '.front.address')

# Windows opened in the TV session by something other than the daemon. The
# display's name is the session's, expanded on the box.
# shellcheck disable=SC2016
display='WAYLAND_DISPLAY=$(systemctl --user show-environment | sed -n "s/^WAYLAND_DISPLAY=//p")'
guest "$display setsid -f foot --title agentv-s16-new sleep 120 >/dev/null 2>&1 </dev/null" >/dev/null 2>&1 || true
guest "$display setsid -f foot --fullscreen --title agentv-s16-fullscreen sleep 120 >/dev/null 2>&1 </dev/null" >/dev/null 2>&1 || true
sleep 4
screen_status >"$RUN_DIR/screen-new.json"
where() {
  jq -r --arg title "$1" '.windows[] | select(.title == $title) | .workspace' "$RUN_DIR/screen-new.json"
}
check "S1.6 a new window opens out of sight" test "$(where agentv-s16-new)" = "special:agentv-held"
check "S1.6 a window that asks for full screen opens out of sight too" test "$(where agentv-s16-fullscreen)" = "special:agentv-held"
check "S1.6 the home screen stays in front of new windows" \
  test "$(jq -r '.front.address' "$RUN_DIR/screen-new.json")" = "$home"
check "S1.6 the screen still shows the TV (OCR)" screen_shows_welcome "success-S1.6-new-windows"

# Focus taken from outside goes back to the TV.
guest_hyprctl "dispatch 'hl.dsp.focus({ window = \"title:agentv-s16-new\" })'" >/dev/null 2>&1 || true
sleep 2
guest_hyprctl "-j activewindow" >"$RUN_DIR/active.json" 2>&1 || true
check "S1.6 focus taken from outside goes back to the home screen" \
  test "$(jq -r '.address' "$RUN_DIR/active.json")" = "$home"
check "S1.6 and the window it went to isn't shown over the TV (OCR)" screen_shows_welcome "success-S1.6-after-focus"

# Omarchy's terminal key does nothing here: the TV session has none of its keys.
before=$(ssh_guest "pgrep -c -x foot" || echo 0)
press meta_l-ret
sleep 3
check "Super+Return, Omarchy's terminal key, opens nothing in the TV session" \
  test "$(ssh_guest "pgrep -c -x foot" || echo 0)" = "$before"

# The home screen crashing: the daemon starts it again, and it's back in
# front, with nothing else in front meanwhile.
pid=$(front '.apps[] | select(.role == "home") | .pid')
seen=$(jq -r '.welcome_shown_count // 0' <<<"$(health)")
ssh_guest "kill -KILL $pid"
sleep 1
capture_console "S1.6-home-crashed"
role=$(front '.front.role // "none"')
check "S1.6 while the home screen is down, no other window takes the screen (in front: $role)" \
  test "$role" = none -o "$role" = home
check "S1.6 nothing else is on the TV's workspace while the home screen is down" \
  test "$(front '[.windows[] | select(.workspace == "1" and .role != "home")] | length')" = "0"
took=$(wait_tv 30 "$seen") || took=""
check "S1.6 the home screen comes back in front after a crash (took ${took:-over 30} s)" test -n "$took"
check "S1.6 it's a new home screen, started by the daemon" \
  test "$(front '.apps[] | select(.role == "home") | .pid')" != "$pid"
check "S1.6 the windows from before are still out of sight" \
  test "$(front '[.windows[] | select(.title | startswith("agentv-s16")) | .workspace] | unique | join(",")')" = "special:agentv-held"
check "S1.6 after the crash the screen shows the TV again (OCR)" screen_shows_welcome "success-S1.6-after-crash"

screen_status >"$RUN_DIR/screen-end.json"
guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/agentv-screen.log" 2>&1 || true
stop_vm
finish
