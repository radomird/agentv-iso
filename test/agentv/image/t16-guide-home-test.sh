#!/bin/bash
#
# T16: holding a gamepad's guide button goes home from Steam, and a short
# press stays Steam's (ADR-084). Before this a gamepad alone couldn't get
# home from Steam at all.
#
# Steam and gamescope are the stand-ins of s3.5-steam-test.sh: neither runs
# on a CI box with no account and no GPU. The gamepad is a stand-in too, a
# uinput device made on the box (gamepad.py), which udev marks as a joystick
# the way it marks a real one. So the whole path is the box's own: udev, the
# input helper reading the gamepad, its word to the screen daemon, and
# Hyprland bringing home in front.
#
# With the stand-in Steam in front: a short press leaves it there, and so
# does a press let go before the second is up. Held, home comes in front
# while the button is still down, Steam keeps running behind it, and opening
# it again brings the same one back. A keyboard's Home key and a remote's
# Home button go home from Steam as they did. What a real Steam does with
# the same presses, its own menu on a short one, is the NUC's to see.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-t16-guide-home-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-t16-guide-home-no-tv"; check "the TV session came up" false; stop_vm; finish; }
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
wait_home 60 >/dev/null || true

# The stand-ins for Steam and gamescope, where their own packages put them,
# on this throwaway box only (s3.5-steam-test.sh says why each is one).
ssh_guest "cat >/tmp/steam" <<'STEAM'
#!/bin/bash
# A stand-in for Steam in AgenTV's image checks: a full-screen window, drawn
# without a GPU, until /tmp/agentv-steam-quit appears, as Exit Steam does.
# mpv draws it in shared memory; if that doesn't stay up, Chromium draws it
# instead.
rm -f /tmp/agentv-steam-quit
mpv --vo=wlshm --idle=yes --force-window=yes --fs --no-audio --no-terminal --title=steam-stand-in &
window=$!
sleep 3
if ! kill -0 "$window" 2>/dev/null; then
  chromium --ozone-platform=wayland --user-data-dir=/tmp/agentv-steam-stand-in --no-first-run --kiosk \
    "data:text/html,<title>steam-stand-in</title><body style='background:%23123'>" &
  window=$!
fi
while [[ ! -e /tmp/agentv-steam-quit ]] && kill -0 "$window" 2>/dev/null; do sleep 0.2; done
kill "$window" 2>/dev/null
wait "$window" 2>/dev/null
exit 0
STEAM
ssh_guest "cat >/tmp/gamescope" <<'GAMESCOPE'
#!/bin/bash
# A stand-in for gamescope in AgenTV's image checks, which have no GPU: it
# runs what comes after --, and it ends when that does, as gamescope does.
while (( $# > 0 )) && [[ $1 != "--" ]]; do shift; done
shift
"$@"
GAMESCOPE
ssh_sudo "install -m 755 /tmp/steam /usr/bin/steam && install -m 755 /tmp/gamescope /usr/bin/gamescope"

# wait_front <role> <seconds>: until <role> is in front.
wait_front() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(front '.front.role // ""') == "$1" ]] && return 0
    sleep 0.3
  done
  return 1
}

# stays_front <role> <seconds>: <role> is in front for that long.
stays_front() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(front '.front.role // ""') == "$1" ]] || return 1
    sleep 0.5
  done
  return 0
}

# Steam running: gamescope and the stand-in's window. The bracket keeps
# pgrep from finding its own command line.
game_running() {
  ssh_guest "pgrep -x gamescope >/dev/null && pgrep -f 'steam-stand-i[n]' >/dev/null"
}

# How many times the screen daemon went home for a held guide button.
held_count() {
  guest "journalctl --user -b --no-pager -u agentv-screen | grep -c 'guide button held'" 2>/dev/null | tail -n 1 || true
}

# The stand-in gamepad, made by the person logged in on the screen.
ssh_guest "cat >/tmp/agentv-gamepad.py" <"$DIR/gamepad.py"
ssh_guest "rm -f /tmp/agentv-gamepad; (nohup python3 -I /tmp/agentv-gamepad.py /tmp/agentv-gamepad >/tmp/agentv-gamepad.log 2>&1 &)"
# pad <button> <seconds>: holds a button for that long. It comes back at
# once, with the button still down.
pad() {
  ssh_guest "echo '$1 $2' >/tmp/agentv-gamepad"
}
# Its event device, once udev has marked it as a joystick.
pad_device() {
  # shellcheck disable=SC2016 # expanded on the box
  ssh_guest 'for node in /sys/class/input/event*; do
    [[ $(cat "$node/device/name" 2>/dev/null) == "AgenTV test gamepad" ]] || continue
    grep -qx "E:ID_INPUT_JOYSTICK=1" "/run/udev/data/c$(cat "$node/dev")" 2>/dev/null && echo "/dev/input/${node##*/}"
  done' 2>/dev/null | head -n 1 || true
}
device=""
started=$SECONDS
while (( SECONDS - started < 20 )) && [[ -z $device ]]; do
  device=$(pad_device)
  [[ -n $device ]] || sleep 1
done
check "a stand-in gamepad is on the box, and udev marks it as a joystick ($device)" test -n "$device"
check "the person logged in on the screen can read it" ssh_guest "test -r '$device'"
[[ -n $device ]] || log "the gamepad said: $(ssh_guest "cat /tmp/agentv-gamepad.log" 2>/dev/null | tr '\n' ' ')"
# The input helper looks for new gamepads every 3 s.
sleep 5

guest "agentv screen open steam" >>"$RUN_DIR/screen.log" 2>&1 || true
up=no
wait_front steam 90 && up=yes
check "the stand-in Steam opens in front" test "$up" = yes
sleep 3
capture_console "success-t16-guide-home-steam"

# A short press is Steam's own.
pad guide 0.15
check "T16 a short press of the guide button leaves Steam in front" stays_front steam 4
# Let go before the second is up, it's still a press.
pad guide 0.5
check "T16 the guide button let go before a second leaves Steam in front" stays_front steam 4
# Another button held isn't the guide button.
pad a 1.6
check "T16 holding another button leaves Steam in front" stays_front steam 4
check "nothing went home for a held guide button so far" test "$(held_count)" = "0"

# Held: home comes in front at the one-second mark, with the button still
# down for seconds after it.
pad guide 8
home=no
wait_front home 5 && home=yes
check "T16 holding the guide button brings home in front, while it's still down" test "$home" = yes
# The gamepad's own word that it was still down then.
released=$(ssh_guest "grep -c '^guide up' /tmp/agentv-gamepad.log" 2>/dev/null || true)
check "the button was still down when home came in front" test "${released:-0}" = "2"
capture_console "success-t16-guide-home-home"
check "T16 Steam keeps running behind home" game_running
check "T16 home lists Steam as a game that's open" \
  test "$(jq -c '[.open[] | select(.role == "steam")] | length' <<<"$(screen_status)" 2>/dev/null)" = "1"
# The rest of the hold, and its release, add nothing.
sleep 8
check "the hold went home once" test "$(held_count)" = "1"
check "home is still in front after the button is let go" test "$(front '.front.role // ""')" = "home"

# On home a press is Home, as it was, and holding it does no more.
pad guide 1.6
check "on home, the guide button leaves home in front" stays_front home 3
check "and a hold there isn't one from a game" test "$(held_count)" = "1"

# Opening Steam again brings the same one back.
guest "agentv screen open steam" >>"$RUN_DIR/screen.log" 2>&1 || true
check "T16 opening Steam again brings it back" wait_front steam 15
check "the same Steam, not a second one" test "$(ssh_guest "pgrep -xc gamescope" 2>/dev/null || true)" = "1"

# A second hold goes home again.
pad guide 1.6
check "T16 holding the guide button goes home from Steam a second time" wait_front home 5
sleep 2

# The other ways home from Steam, as they were: a keyboard's Home key, and a
# remote's Home button, which is the phone's too.
guest "agentv screen open steam" >>"$RUN_DIR/screen.log" 2>&1 || true
wait_front steam 15 || true
guest "agentv input key home-key" >>"$RUN_DIR/input.log" 2>&1 || true
check "a keyboard's Home key goes home from Steam" wait_front home 10
guest "agentv screen open steam" >>"$RUN_DIR/screen.log" 2>&1 || true
wait_front steam 15 || true
guest "agentv input key home" >>"$RUN_DIR/input.log" 2>&1 || true
check "a remote's Home button, the phone's too, goes home from Steam" wait_front home 10
check "Steam is still running after all of it" game_running

# A gamepad that goes away while its guide button is down leaves nothing to
# go home later.
guest "agentv screen open steam" >>"$RUN_DIR/screen.log" 2>&1 || true
wait_front steam 15 || true
before=$(held_count)
pad guide 30
sleep 0.3
ssh_guest "pkill -f agentv-gamepad.p[y]" || true
check "T16 a gamepad that goes away mid-hold leaves Steam in front" stays_front steam 5
check "and nothing went home for it" test "$(held_count)" = "$before"

ssh_guest "cat /tmp/agentv-gamepad.log" >"$RUN_DIR/gamepad.log" 2>&1 || true
guest "journalctl --user -b --no-pager -u agentv-screen -u agentv-input" >"$RUN_DIR/guide-home.log" 2>&1 || true
ssh_guest "touch /tmp/agentv-steam-quit" || true
stop_vm
finish
