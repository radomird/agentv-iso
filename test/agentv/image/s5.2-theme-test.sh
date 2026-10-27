#!/bin/bash
#
# S5.2: changing the theme on Omarchy's desktop changes the TV within 2 s
# (ADR-012). First setup's look (board 12): Gruvbox, picked with the TV's
# keys, is set with Omarchy's own omarchy-theme-set through the screen
# daemon, and the TV turns Gruvbox. Then a theme set the way Omarchy's
# desktop sets it, omarchy-theme-set as the owner, is timed on the box
# itself, from the command's start to the daemon having its colours, and the
# TV's own screen turns light with Catppuccin Latte.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# until_json <url path> <jq filter> <seconds>: until the filter on what the
# daemon answers there is true.
until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000$1" 2>/dev/null | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 1
}

setup_post() {
  ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '$2' http://127.0.0.1:3000$1" >>"$RUN_DIR/setup-posts.log" 2>&1
}

# brightness <name>: the whole screen's mean brightness, 0 to 1.
brightness() {
  local shot="$RUN_DIR/$1.ppm"
  screendump "$shot"
  magick "$shot" -colorspace gray -format '%[fx:mean]' info: 2>/dev/null || echo 0
}

start_vm_from_base
wait_for_ssh 300 failure-S5.2-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
check "the owner's theme hand-over is waiting in their session" test "$(guest "systemctl --user is-active agentv-theme.path")" = "active"

# Setup's look, with the steps before it moved on as the setup screens do.
setup_post /api/setup/finish '{"step": "welcome", "keyboard": true}'
setup_post /api/setup/ready '{"update": "none"}'
for step in ready ai people; do setup_post /api/setup/finish "{\"step\": \"$step\"}"; done
setup_post /api/setup/goal '{"goal": "streaming"}'
setup_post /api/setup/finish '{"step": "goal"}'
setup_post /api/setup/finish '{"step": "apps"}'
check "setup is at its look" until_json /api/setup '.setup.step == "theme"' 30
check "the look offers Tokyo Night, Gruvbox and Catppuccin Latte, and the TV has Tokyo Night" \
  until_json /api/themes '([.themes[].id] == ["tokyo-night", "gruvbox", "catppuccin-latte"]) and .current == "tokyo-night"' 30
check "the look is on the TV (OCR)" ocr_finds success-S5.2-look "pick a look|describe your own" 30
capture_console "success-S5.2-look"

started=$SECONDS
for key in right enter; do
  guest "agentv input key $key" >>"$RUN_DIR/input.log" 2>&1 || true
  sleep 1
done
check "S5.2 Gruvbox picked on the TV is set with Omarchy's own command, and the TV has it" until_json /api/themes '.current == "gruvbox"' 60
log "Gruvbox from the TV took $(( SECONDS - started )) s, Omarchy's own command included"
guest "cat ~/.local/state/omarchy/current/theme.name" >"$RUN_DIR/theme-name.txt" 2>&1 || true
check "and it's Omarchy's theme now" grep -qx gruvbox "$RUN_DIR/theme-name.txt"
capture_console "success-S5.2-gruvbox"
for key in up enter; do
  guest "agentv input key $key" >>"$RUN_DIR/input.log" 2>&1 || true
  sleep 1
done
check "continue finishes setup" until_json /api/setup '.setup.done' 30
took=$(wait_home 60) || took=""
check "and home takes over${took:+ (after $took s)}" test -n "$took"
sleep 3
dark=$(brightness gruvbox-home)

# As Omarchy's desktop does it: omarchy-theme-set, as the owner, timed on
# the box from its start to the daemon having the new theme's colours. The
# script runs there, so its expansions are the box's.
# shellcheck disable=SC2016
script='export OMARCHY_PATH=/usr/share/omarchy PATH=/usr/share/omarchy/bin:$PATH
start=$(date +%s%N)
omarchy-theme-set catppuccin-latte >/tmp/s5.2-theme-set.log 2>&1 &
until curl -fsS --max-time 1 http://127.0.0.1:3000/api/theme.css 2>/dev/null | grep -qi -- "--background: #eff1f5;"; do
  (( ($(date +%s%N) - start) / 1000000 > 30000 )) && { echo 30001; exit 0; }
  sleep 0.05
done
echo $(( ($(date +%s%N) - start) / 1000000 ))
wait'
ms=$(guest "$script" | tail -n 1)
check "S5.2 a theme changed as on Omarchy's desktop reaches the TV within 2 s (${ms:-?} ms)" test "${ms:-99999}" -le 2000
sleep 2
light=$(brightness latte-home)
capture_console "success-S5.2-latte"
check "S5.2 and the TV's own screen turns light with Catppuccin Latte (brightness $dark, then $light)" \
  awk -v d="$dark" -v l="$light" 'BEGIN { exit !(l > 0.6 && d < 0.4) }'
guest "cat /tmp/s5.2-theme-set.log; journalctl --user -b --no-pager -u agentv-theme" >"$RUN_DIR/theme.log" 2>&1 || true

stop_vm
finish
