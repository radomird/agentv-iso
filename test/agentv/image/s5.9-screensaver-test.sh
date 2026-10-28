#!/bin/bash
#
# S5.9: Omarchy's terminal screensaver on the ambient screen (ADR-049). With
# "terminal" picked in Settings → Look, the ambient screen comes up on its
# usual timing, set to 45 s here with agentv screen idle-after, and the
# screen daemon brings agentv-screensaver in front: ttfx's effects in a foot
# of its own, in the current theme's colours. The box is on Tokyo Night, so
# the screen is mostly its background. One key on the remote, then one from
# a paired phone, each end it and bring back the app that was in front.
#
# A box from before ADR-049 has no ambient style in its settings, and this
# check stands down.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

wait_front() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(front '.front.role // ""') == "$1" ]] && return 0
    sleep 0.5
  done
  return 1
}

# The colour most of the screen is, as a hex colour. awk reads the whole
# histogram: a head that stops early kills sort with SIGPIPE once ttfx puts
# enough colours on the screen, and pipefail ends the check with it.
most_of_screen() {
  local shot="$RUN_DIR/$1.ppm"
  screendump "$shot"
  { magick "$shot" -format %c histogram:info:- 2>/dev/null || true; } |
    awk '$1 + 0 > most { most = $1 + 0; line = $0 } END { if (match(line, /#[0-9A-Fa-f]{6}/)) print substr(line, RSTART, RLENGTH) }'
}

# Leaves the TV alone until the screensaver is in front. Prints how many
# seconds that took.
until_screensaver() {
  local started=$SECONDS
  while (( SECONDS - started < $1 )); do
    if [[ $(front '[.ambient, .front.role] | map(tostring) | join(" ")') == "true screensaver" ]]; then
      echo $(( SECONDS - started ))
      return 0
    fi
    sleep 1
  done
  return 1
}

start_vm_from_base
wait_for_ssh 300 failure-S5.9-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true

ssh_guest "curl -fsS http://127.0.0.1:3000/api/home" >"$RUN_DIR/home.json" 2>&1 || true
if ! jq -e '.settings | has("ambient")' "$RUN_DIR/home.json" >/dev/null 2>&1; then
  log "This agentv has no terminal screensaver, from before ADR-049; S5.9 waits for it"
  stop_vm
  finish
  exit 0
fi

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "setup skipped, home is in front${took:+ (after $took s)}" test -n "$took"
check "the box is on Tokyo Night" grep -qx tokyo-night <(guest "cat ~/.local/state/omarchy/current/theme.name" 2>/dev/null)

# Settings → Look: the ambient screen shows the terminal screensaver.
ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"ambient\": \"terminal\"}' http://127.0.0.1:3000/api/settings" >"$RUN_DIR/settings.json" 2>&1 || true
check "Settings takes the terminal screensaver" jq -e '.settings.ambient == "terminal"' <(ssh_guest "curl -fsS http://127.0.0.1:3000/api/home" 2>/dev/null)

# An app in front, paused, as in the ambient screen's own check.
ssh_guest "mkdir -p /tmp/agentv-page && cat >/tmp/agentv-page/index.html" <"$(dirname -- "${BASH_SOURCE[0]}")/pages/media.html"
ssh_guest "cd /tmp/agentv-page && (nohup python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &)"
guest "agentv screen open http://127.0.0.1:8765/" >>"$RUN_DIR/screen.log" 2>&1 || true
check "the stand-in app opens in front" wait_front web 60
guest "agentv screen idle-after 45" >>"$RUN_DIR/screen.log" 2>&1 || true

log "Leaving the TV alone, with the app paused"
took=$(until_screensaver 150) || took=""
check "S5.9 the terminal screensaver comes up on the ambient screen's timing${took:+ (after $took s, with 45 s set)}" test -n "$took"
check "S5.9 it's ttfx, in a foot of its own" guest "pgrep -x ttfx && pgrep -f org.agentv.screensaver"
sleep 3
colour=$(most_of_screen success-S5.9-screensaver)
log "Most of the screen is $colour"
check "S5.9 in the theme's colours: Tokyo Night's background, not black" test "${colour,,}" = "#1a1b26"
guest_hyprctl clients -j >"$RUN_DIR/clients.json" 2>&1 || true

# One key on the remote.
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
check "S5.9 one key on the remote brings back the app" wait_front web 15
check "and the ambient screen is over" test "$(front '.ambient')" = "false"
sleep 2
check "with no ttfx left" test -z "$(guest 'pgrep -x ttfx' 2>/dev/null)"

# Then a press from a paired phone.
code=$(ssh_guest "curl -fsS -X POST http://127.0.0.1:3000/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
token=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\": \"$code\", \"name\": \"image check\"}' http://127.0.0.1:3001/api/phone/pair" 2>/dev/null | jq -r '.token // empty')
check "a phone pairs" test -n "$token"
log "Leaving the TV alone again"
took=$(until_screensaver 150) || took=""
check "S5.9 the screensaver comes up again${took:+ (after $took s)}" test -n "$took"
ssh_guest "curl -fsS -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -d '{\"key\": \"enter\"}' http://127.0.0.1:3001/api/phone/remote" >"$RUN_DIR/phone-key.json" 2>&1 || true
check "S5.9 one press on the phone brings back the app" wait_front web 15
check "and the ambient screen is over" test "$(front '.ambient')" = "false"

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen-journal.log" 2>&1 || true
stop_vm
finish
