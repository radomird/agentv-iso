#!/bin/bash
#
# The phone's d-pad in a web app made for a desktop, on an installed box
# (ADR-008). A stand-in page with no arrow keys of its own and no focus
# outline opens in the services' Chromium. A paired phone's arrows move the
# focus along its row of tiles, with AgenTV's ring around it, OK presses one,
# OK on a link opens it, and Back goes back. The page's title says what has
# focus, and Hyprland reads it from its window.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-dpad-web-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-dpad-web-no-tv"; check "the TV session came up" false; stop_vm; finish; }

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

# A phone, paired the way phone-test.sh pairs one: Settings → Phones on the
# TV, then the code it shows.
guest "agentv screen settings phones" >"$RUN_DIR/settings.json" 2>&1 || true
sleep 2
guest "agentv input key enter" >"$RUN_DIR/input.log" 2>&1 || true
sleep 1
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 3
code=$(ssh_guest "curl -fsS http://127.0.0.1:3000/api/phones" 2>/dev/null | jq -r '.pairing.code // empty' 2>/dev/null || true)
address=$(ssh_guest "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -n 1" 2>/dev/null || true)
phone="http://$address:3001"
token=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\":\"$code\",\"name\":\"test phone\"}' $phone/api/phone/pair" 2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)
check "a phone pairs" test -n "$token"

# press <key>: the phone's d-pad, through the daemon, as the web companion
# sends it.
press() {
  ssh_guest "curl -fsS -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -d '{\"key\":\"$1\"}' $phone/api/phone/remote" >>"$RUN_DIR/remote.log" 2>&1 || true
  sleep 0.7
}

# The page's title, from the window in front.
title() {
  front '.front.title // ""'
}

# wait_title <regex> <seconds>
wait_title() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(title) =~ $1 ]] && return 0
    sleep 0.3
  done
  return 1
}

# The page, served on the box itself.
ssh_guest "mkdir -p /tmp/agentv-dpad && cat >/tmp/agentv-dpad/index.html" <"$(dirname -- "${BASH_SOURCE[0]}")/pages/dpad.html"
ssh_guest "cd /tmp/agentv-dpad && (nohup python3 -m http.server 8766 --bind 127.0.0.1 >/dev/null 2>&1 &)"

guest "agentv screen open http://127.0.0.1:8766/" >>"$RUN_DIR/screen.log" 2>&1 || true
check "the stand-in web app opens in front" wait_title "^Stand-in$" 60
sleep 2

# Down twice: past the links along the top, to the row of tiles.
for _ in 1 2 3; do
  [[ $(title) =~ ^focus\ tile- ]] && break
  press down
done
check "the phone's down moves the focus to the row of tiles (title: $(title))" wait_title "^focus tile-1$" 5
press right
press right
check "and right moves it along the row (title: $(title))" wait_title "^focus tile-3$" 5
capture_console "success-dpad-web-ring"

# The ring is pure white, and nothing else on the page is.
white=0
if [[ -s $RUN_DIR/success-dpad-web-ring.png ]]; then
  white=$(magick "$RUN_DIR/success-dpad-web-ring.png" -fill black +opaque white -fill white -opaque white -format "%[fx:round(mean*w*h)]" info: 2>/dev/null || echo 0)
fi
check "AgenTV's ring shows around what has focus ($white white pixels)" test "${white:-0}" -gt 1000

press enter
check "OK presses the tile (title: $(title))" wait_title "^picked 3$" 5

press up
check "up reaches the links along the top (title: $(title))" wait_title "^focus (films|series)$" 5
press enter
check "OK on a link opens it (title: $(title))" wait_title "^next$" 10
press back
check "Back goes back a page (title: $(title))" wait_title "^(Stand-in|focus |picked )" 10
check "and the app is still in front" test "$(front '.front.role // ""')" = "web"

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen-daemon.log" 2>&1 || true
check "the screen daemon gave the page the d-pad's ring and Back" bash -c "! grep -q \"the d-pad's ring and Back aren't\" '$RUN_DIR/screen-daemon.log'"

stop_vm
finish
