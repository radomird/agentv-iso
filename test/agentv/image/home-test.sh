#!/bin/bash
#
# The home screen (stage 2): once setup is done, the TV shows AgenTV's
# launcher, which the daemon serves, in the Omarchy theme's colours, with
# the built-in clock and weather on it (stage 3). The remote's keys move
# around it, and setting up again brings the welcome page
# back, and a layout stays as it was left when the box restarts. Layer 4
# checks the launcher itself in a Chromium (S2.3 to S2.7); this checks it's
# what an installed box shows.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-home-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-home-no-tv"; check "the TV session came up" false; stop_vm; finish; }

# screen_says <name> <text> [<seconds>]: until OCR finds <text> on the TV,
# keeping the last screenshot as <name>.
screen_says() {
  local started=$SECONDS

  while (( SECONDS - started < ${3:-30} )); do
    ocr_screen >"$RUN_DIR/$1.txt" 2>/dev/null || true
    if grep -qi "$2" "$RUN_DIR/$1.txt"; then
      capture_console "$1"
      return 0
    fi
    sleep 2
  done
  capture_console "$1"
  return 1
}

# The theme's colours, from the TV session's start (agentv-theme.service).
check "the home screen's template is in the owner's Omarchy themes, and the theme-set hook beside it" \
  guest "test -L ~/.config/omarchy/themed/launcher.css.tpl && test -f ~/.config/omarchy/hooks/theme-set.d/agentv"
ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/theme.css" >"$RUN_DIR/theme.css" 2>/dev/null || true
background=$(guest "/usr/share/omarchy/bin/omarchy-theme-color background" 2>/dev/null || true)
check "the TV has the Omarchy theme's colours (its background is ${background:-unknown})" \
  grep -qix "  --background: ${background:-none};" "$RUN_DIR/theme.css"

# Setup done: the page reloads itself and the launcher draws the home grid.
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
check "agentv setup skip marks setup done (daemon /health)" \
  test "$(jq -r '.screen' <<<"$(health)" 2>/dev/null)" = "home"
check "with setup done, the TV shows the home screen's grid (OCR)" screen_says "success-home-grid" "installed"
check "the home screen has its status bar (OCR)" grep -qi "settings" "$RUN_DIR/success-home-grid.txt"
check "the home screen is still in front, full screen" \
  test "$(front '[.front.role, .front.fullscreen] | join(" ")')" = "home 2"

# The built-ins come first (stage 3), so the all apps tile's in the first
# row after them; the focus starts on the first tile.
check "the built-in clock and weather are on home (OCR)" bash -c "grep -qi clock '$RUN_DIR/success-home-grid.txt' && grep -qi weather '$RUN_DIR/success-home-grid.txt'"
rights=$(ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/home" 2>/dev/null | jq '[.layout | sort_by(.y, .x)[] | .id] | index("apps") // 0' 2>/dev/null || echo 0)
for _ in $(seq 1 "$rights"); do
  guest "agentv input key right" >>"$RUN_DIR/input.log" 2>&1 || true
done
sleep 1

# The remote's keys: OK on the all apps tile opens the apps page, back
# comes home.
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
check "OK on the all apps tile opens the apps page (OCR)" screen_says "success-home-apps" "on your home" 15
guest "agentv input key back" >>"$RUN_DIR/input.log" 2>&1 || true
check "back comes home again (OCR)" screen_says "success-home-back" "installed" 15

# The layout is the daemon's to keep (S2.4): a tile moved stays where it was
# put when the box restarts, and the TV comes back to home, not setup.
ssh_guest "curl -fsS -X PUT -H 'Content-Type: application/json' -d '{\"layout\":[{\"id\":\"apps\",\"x\":3,\"y\":2,\"size\":\"s\"}]}' http://127.0.0.1:3000/api/layout" \
  >"$RUN_DIR/layout.json" 2>&1 || true
log "Restarting the box with the all apps tile moved"
ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
sleep 15
wait_for_ssh 300 failure-home-reboot-ssh-timeout || exit 1
started=$SECONDS
until [[ $(front '.front.role // ""') == "home" ]] || (( SECONDS - started > 240 )); do sleep 1; done
check "after a restart the TV comes back to the home screen's grid (OCR)" screen_says "success-home-reboot" "installed" 60
# What the TV session did after the restart, and which windows it has.
guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen-after-restart.log" 2>&1 || true
guest_hyprctl "clients -j" >"$RUN_DIR/clients-after-restart.json" 2>&1 || true
if ! grep -qi "installed" "$RUN_DIR/success-home-reboot.txt" 2>/dev/null; then
  tail -n 40 "$RUN_DIR/screen-after-restart.log"
  jq -c '[.[] | {class, title, workspace: .workspace.name, mapped, hidden, fullscreen}]' "$RUN_DIR/clients-after-restart.json" 2>&1 || true
  screen_status
fi
check "S2.4 a moved tile is where it was put after the box restarts" \
  test "$(ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/home" 2>/dev/null | jq -c '[.layout[] | "\(.id) \(.size)@\(.x),\(.y)"]')" = '["apps s@3,2"]'

# Setting up again brings the welcome page back, without a restart.
seen=$(jq -r '.welcome_shown_count // 0' <<<"$(health)" 2>/dev/null || echo 0)
guest "agentv setup reset" >>"$RUN_DIR/setup.log" 2>&1 || true
took=$(wait_tv 30 "$seen") || took=""
check "agentv setup reset brings the welcome page back (took ${took:-over 30} s)" test -n "$took"
check "the welcome page is on the screen again (OCR)" screen_shows_welcome "success-home-reset"

ssh_guest "journalctl -b --no-pager -u agentv-daemon" >"$RUN_DIR/daemon.log" 2>&1 || true
guest "journalctl --user -b --no-pager -u agentv-theme" >"$RUN_DIR/theme.log" 2>&1 || true
stop_vm
finish
