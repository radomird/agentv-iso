#!/bin/bash
#
# S1.1: a cold boot lands in AgenTV's TV session (ADR-031) on the welcome
# page with no manual step, and nothing of Omarchy's desktop shows in it: no
# bar, notice, screensaver or idle lock. It waits past the time Omarchy's
# screensaver would start, and the TV is still the welcome page.
#
# Also the rest of what the TV session is made of: the virtual input
# device's keys reach the home screen, a toast draws over it (part of S1.5),
# and the home screen's frames can be measured (S1.5's 60 fps is the NUC's).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

log "Booting the installed system with no key pressed"
start_vm_from_base
wait_for_ssh 300 failure-S1.1-ssh-timeout || exit 1

conf=/etc/sddm.conf.d/zz-agentv-autologin.conf
check "S1.1 SDDM logs the owner in to the TV session, and back in after a log-out" \
  ssh_guest "grep -qx 'User=$GUEST_USER' $conf && grep -qx 'Session=agentv.desktop' $conf && grep -qx 'Relogin=true' $conf"

if took=$(wait_tv 240); then
  log "The home screen was in front ${took} s after SSH answered"
fi
screen_status >"$RUN_DIR/screen.json"
health >"$RUN_DIR/health.json"
check "S1.1 the TV session is on, with the home screen in front, full screen and focused" \
  test "$(jq -r '[.front.role, .front.workspace, .front.fullscreen] | join(" ")' "$RUN_DIR/screen.json")" = "home 1 2"
check "S1.1 the home screen is the welcome page (daemon /health)" \
  test "$(jq -r '.welcome_shown' "$RUN_DIR/health.json")" = "true"
check "S1.1 the home screen runs in a Chromium of its own, as a kiosk app window" \
  ssh_guest "pgrep -af 'user-data-dir=/var/lib/agentv/chromium-home' | grep -- '--kiosk' | grep -q -- '--app=http://127.0.0.1:3000/'"
check "the TV session runs Hyprland with AgenTV's setup" \
  ssh_guest "pgrep -af 'Hyprland.*--config /usr/share/agentv/session/hypr.lua' >/dev/null"

# Nothing of Omarchy's desktop: its shell draws the bar, the notices, the
# screensaver and the lock, and its user services hang off
# graphical-session.target.
check "S1.1 Omarchy's shell isn't running: no bar, notices, screensaver or idle lock" \
  ssh_guest "! pgrep -f '$OMARCHY_SHELL' >/dev/null"
check "S1.1 graphical-session.target isn't started, so none of Omarchy's desktop services are" \
  guest "! systemctl --user is-active --quiet graphical-session.target"
check "S1.1 no Omarchy overlay is on the screen" \
  test "$(jq -r '[.layers[] | select(startswith("omarchy"))] | length' "$RUN_DIR/screen.json")" = "0"
check "S1.1 the screen shows the welcome page (OCR)" screen_shows_welcome "success-S1.1-tv-session"
check "S1.1 no bar: no weekday or clock on the screen" \
  bash -c "! grep -Eqi '(mon|tues|wednes|thurs|fri|satur|sun)day' '$RUN_DIR/success-S1.1-tv-session.txt'"
ocr_top "$RUN_DIR/success-S1.1-tv-session.png" "$RUN_DIR/top-at-start.txt" || true
check "S1.1 no notice over the TV at the start, Hyprland's or anyone's" \
  bash -c "! grep -Eqi 'xdg|environment|warning|error|config|hyprland|update|keybinding' '$RUN_DIR/top-at-start.txt'"

# Omarchy's screensaver would start after two and a half idle minutes.
log "Leaving the TV idle for three minutes"
sleep 180
check "S1.1 after three idle minutes the TV is still the welcome page: no screensaver, no lock" \
  screen_shows_welcome "success-S1.1-after-idle"
check "S1.1 after three idle minutes the home screen is still in front" \
  test "$(front '.front.role')" = "home"

# The virtual input device (ADR-008): keys sent to it reach the home screen.
# Not Enter: on setup's welcome screen it carries on to getting ready, which
# updates the box first. On a pull request's run that's edge's agentv, often
# newer than the one being checked, and the update restarts the TV session.
guest_hyprctl "-j devices" >"$RUN_DIR/devices.json" 2>&1 || true
check "the virtual input device is on: Hyprland sees AgenTV remote" \
  jq -e '[.keyboards[].name] | any(test("agentv-remote"))' "$RUN_DIR/devices.json"
guest "agentv screen keys 6" >"$RUN_DIR/keys.json" 2>&1 &
keys=$!
sleep 2
guest "agentv input key up down right" >"$RUN_DIR/input.txt" 2>&1 || true
wait "$keys" || true
check "the virtual input device's keys reach the home screen" \
  test "$(jq -c '.keys' "$RUN_DIR/keys.json" 2>/dev/null)" = '["ArrowUp","ArrowDown","ArrowRight"]'

# A toast over the app in front (S1.5 on the NUC is a toast over a film).
guest "agentv screen toast 'AgenTV toast over the TV'" >"$RUN_DIR/toast.json" 2>&1 || true
sleep 1
check "a toast draws over the app in front, as an overlay" \
  test "$(front '[.layers[] | select(. == "agentv-toast")] | length')" -ge 1
capture_console "success-S1.1-toast"
# The toast is in the top right, beside setup's own text: ocr_finds reads the
# right of the screen too.
check "the toast is on the screen (OCR)" ocr_finds toast "toast over the TV" 15

guest "agentv screen frames 3" >"$RUN_DIR/frames.json" 2>&1 || true
log "The home screen in the VM: $(cat "$RUN_DIR/frames.json")"
check "the home screen's frames can be measured (S1.5's 60 fps is checked on the NUC)" \
  test "$(jq -r '.frames // 0' "$RUN_DIR/frames.json")" -gt 0

guest "journalctl --user -b --no-pager -u agentv-screen -u agentv-input -u agentv-toast" >"$RUN_DIR/tv-session.log" 2>&1 || true
stop_vm
finish
