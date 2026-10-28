#!/bin/bash
#
# S5.8: with a theme that ships backgrounds, home shows Omarchy's current one
# with the theme named as its credit, and follows the desktop to the next
# (ADR-048). The box was installed on Tokyo Night, which ships its own, and a
# new box shows them by default. The screen daemon hands the daemon each of
# them once, and which one Omarchy shows: that's the very file Omarchy's
# current background links to. Home has it behind the tiles, the ambient
# screen credits Tokyo Night, and when Omarchy's desktop moves to the next
# background (omarchy-theme-bg-next), so does home. The contrast in every
# theme is layer 4's.
#
# A box from before ADR-048 has no theme's own, and this check stands down.

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

# busyness <name>: how much the whole screen varies, 0 to 1. A picture
# behind the tiles varies far more than the theme's plain colour.
busyness() {
  local shot="$RUN_DIR/$1.ppm"
  screendump "$shot"
  magick "$shot" -colorspace gray -format '%[fx:standard_deviation]' info: 2>/dev/null || echo 0
}

# apart <shot> <shot>: how far apart two screens of busyness's are below
# home's top row of tiles, 0 to 1. With the pixel field, home has the
# theme's plain colour there; with a picture, the picture. magick compare
# exits 1 when the two differ, which is the point here.
apart() {
  local w h one
  read -r w h < <(magick identify -format '%w %h' "$RUN_DIR/$1.ppm" 2>/dev/null)
  for one in "$1" "$2"; do
    magick "$RUN_DIR/$one.ppm" -crop "${w:-0}x$(( ${h:-0} * 45 / 100 ))+0+$(( ${h:-0} * 45 / 100 ))" +repage "$RUN_DIR/$one-below.png" 2>/dev/null
  done
  { magick compare -metric RMSE "$RUN_DIR/$1-below.png" "$RUN_DIR/$2-below.png" null: 2>&1 || true; } | sed -nE 's/.*\(([0-9.e+-]+)\).*/\1/p'
}

# The id of the picture Omarchy's current background links to, as the TV
# names it: the start of its SHA-256.
omarchy_current() {
  guest "sha256sum \"\$(readlink -f ~/.local/state/omarchy/current/background)\"" 2>/dev/null | cut -c1-16
}

start_vm_from_base
wait_for_ssh 300 failure-S5.8-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true

ssh_guest "curl -fsS http://127.0.0.1:3000/api/backgrounds" >"$RUN_DIR/backgrounds.json" 2>&1 || true
if ! jq -e 'has("theme")' "$RUN_DIR/backgrounds.json" >/dev/null 2>&1; then
  log "This agentv has no theme's own backgrounds, from before ADR-048; S5.8 waits for it"
  stop_vm
  finish
  exit 0
fi

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "setup skipped, home is in front${took:+ (after $took s)}" test -n "$took"
check "the box is on Tokyo Night" grep -qx tokyo-night <(guest "cat ~/.local/state/omarchy/current/theme.name" 2>/dev/null)

# Every one Omarchy would go through, as it finds them when it sets a theme.
shipped=$(guest "find -L ~/.config/omarchy/backgrounds/tokyo-night/ ~/.local/state/omarchy/current/theme/backgrounds/ -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \\) 2>/dev/null | wc -l")
check "S5.8 the daemon has Tokyo Night's own, all $shipped of them" \
  until_json /api/backgrounds ".theme.name == \"tokyo-night\" and (.theme.items | length) == ${shipped:-0} and $((${shipped:-0} > 0))" 120
check "S5.8 and shows them, by default" until_json /api/backgrounds '.source == "theme"' 10
now=$(omarchy_current)
check "S5.8 home's is the one Omarchy shows ($now)" until_json /api/backgrounds ".theme.current == \"$now\"" 30
check "each credited to the theme" until_json /api/backgrounds '[.theme.items[].credit.text] | all(. == "tokyo night")' 10
check "kept in /var/lib/agentv/backgrounds, the daemon's own" ssh_sudo "test -f /var/lib/agentv/backgrounds/theme/$now.jpg -o -f /var/lib/agentv/backgrounds/theme/$now.png"
sleep 3
busy=$(busyness home-theme)
capture_console "success-S5.8-home"

# The same home on the pixel field, for what the theme's own adds.
ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"source\": \"field\"}' http://127.0.0.1:3000/api/backgrounds" >/dev/null 2>&1 || true
sleep 3
plain=$(busyness home-field)
# A dim picture varies little more than the plain colour does, so it's the
# two screens' difference below the tiles that says the picture's there.
gap=$(apart home-theme home-field)
check "S5.8 home has it behind the tiles (the screen below them is ${gap:-?} apart from the pixel field's, out of 1; it varies $busy, and $plain on the field)" \
  awk -v d="${gap:-0}" 'BEGIN { exit !(d > 0.03) }'
ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"source\": \"theme\"}' http://127.0.0.1:3000/api/backgrounds" >/dev/null 2>&1 || true
sleep 2

# The ambient screen credits the theme.
guest "agentv screen ambient" >"$RUN_DIR/ambient.log" 2>&1 || true
check "S5.8 the ambient screen credits Tokyo Night (OCR)" ocr_finds success-S5.8-ambient "tokyo night" 30
capture_console "success-S5.8-ambient"
guest "agentv screen home" >>"$RUN_DIR/ambient.log" 2>&1 || true
sleep 2

# Omarchy's desktop moves on to its next background: so does home.
guest "OMARCHY_PATH=/usr/share/omarchy PATH=/usr/share/omarchy/bin:\$PATH omarchy-theme-bg-next" >"$RUN_DIR/bg-next.log" 2>&1 || true
next=$(omarchy_current)
check "Omarchy's desktop moved on to another background ($now, then $next)" test -n "$next" -a "$next" != "$now"
check "S5.8 home follows it" until_json /api/backgrounds ".theme.current == \"$next\"" 30
check "and still has every one of them" until_json /api/backgrounds "(.theme.items | length) == ${shipped:-0}" 5
capture_console "success-S5.8-next"
guest "journalctl --user -b --no-pager -u agentv-screen | grep -i 'themes:' | tail -n 20" >"$RUN_DIR/screen-themes.log" 2>&1 || true

stop_vm
finish
