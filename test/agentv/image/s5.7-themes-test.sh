#!/bin/bash
#
# S5.7: setup and Settings → Look list every theme on the box, including one
# installed on Omarchy's desktop with `omarchy theme install`, and picking
# any of them changes the TV and the desktop within 2 s (ADR-048).
#
# The theme installed here comes from a git repository on the box itself,
# made from Omarchy's own Nord with an accent of its own, so nothing is
# fetched from outside. `omarchy theme install` names it "aurora" after the
# repository and sets it, as on the desktop. The screen daemon reads the
# person's themes and hands the list to the daemon, which Look reads. Then
# Omarchy's desktop moves to another theme, and aurora is picked with the
# TV's keys in Settings → Look, timed on the box from the key to the TV and
# the desktop both having it.
#
# A box from before ADR-048 offers three looks, and this check stands down.

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

keys() {
  local key
  for key in "$@"; do
    guest "agentv input key $key" >>"$RUN_DIR/input.log" 2>&1 || true
    sleep 0.6
  done
}

start_vm_from_base
wait_for_ssh 300 failure-S5.7-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true

ssh_guest "curl -fsS http://127.0.0.1:3000/api/themes" >"$RUN_DIR/themes-before.json" 2>&1 || true
if ! jq -e '[.themes[].id] | index("nord")' "$RUN_DIR/themes-before.json" >/dev/null 2>&1; then
  log "This agentv offers $(jq '.themes | length' "$RUN_DIR/themes-before.json" 2>/dev/null || echo no) looks, from before ADR-048; S5.7 waits for it"
  stop_vm
  finish
  exit 0
fi

# Omarchy's themes, as its own theme menu finds them.
omarchy_themes() {
  guest "find /usr/share/omarchy/themes ~/.config/omarchy/themes -mindepth 1 -maxdepth 1 \\( -type d -o -type l \\) -printf '%f\\n' 2>/dev/null | sort -u" 2>/dev/null
}
# Look's list and Omarchy's, and what's in only one of them in the log when
# they differ. The image check's container has no diff, so bash compares
# them and comm says how.
same_themes() {
  jq -r '.themes[].id' "$RUN_DIR/$1" | sort >"$RUN_DIR/$1.look.txt"
  omarchy_themes | sort >"$RUN_DIR/$1.omarchy.txt"
  [[ $(<"$RUN_DIR/$1.look.txt") == "$(<"$RUN_DIR/$1.omarchy.txt")" ]] && return 0
  printf 'Look and Omarchy differ (only in Look, then only in Omarchy, indented):\n%s\n' "$(comm -3 "$RUN_DIR/$1.look.txt" "$RUN_DIR/$1.omarchy.txt")" >&3
  return 1
}
exec 3>&1
check "S5.7 Look lists every theme Omarchy ships ($(jq '.themes | length' "$RUN_DIR/themes-before.json"))" same_themes themes-before.json
check "Tokyo Night first" jq -e '.themes[0].id == "tokyo-night"' "$RUN_DIR/themes-before.json"

# As on Omarchy's desktop: `omarchy theme install`, from a repository on the
# box. The script runs there, so its expansions are the box's.
# shellcheck disable=SC2016
install='set -e
export OMARCHY_PATH=/usr/share/omarchy PATH=/usr/share/omarchy/bin:$PATH
repo=/tmp/omarchy-aurora-theme.git
rm -rf "$repo"
cp -r /usr/share/omarchy/themes/nord "$repo"
cd "$repo"
sed -i "s/^accent = .*/accent = \"#a3be8c\"/" colors.toml
git init -q
git add -A
git -c user.name=check -c user.email=check@agentv.invalid commit -qm aurora
omarchy theme install "file://$repo"'
guest "$install" >"$RUN_DIR/install.log" 2>&1 || true
check "omarchy theme install puts aurora in the person's themes" guest "test -f ~/.config/omarchy/themes/aurora/colors.toml"
check "S5.7 it's a look within moments, said to be installed" until_json /api/themes '[.themes[] | select(.id == "aurora" and .note == "installed")] | length == 1' 20
check "and the TV has it, as Omarchy set it" until_json /api/themes '.current == "aurora"' 20
accent_is() {
  ssh_guest "curl -fsS http://127.0.0.1:3000/api/theme.css" 2>/dev/null | grep -qi -- "--accent: $1;"
}
check "in its own accent" accent_is "#a3be8c"
ssh_guest "curl -fsS http://127.0.0.1:3000/api/themes" >"$RUN_DIR/themes-installed.json" 2>&1 || true
check "S5.7 and Look still lists every theme Omarchy has, aurora among them" same_themes themes-installed.json

# Setup's look lists it too.
setup_post /api/setup/finish '{"step": "welcome", "keyboard": true}'
setup_post /api/setup/ready '{"update": "none"}'
for step in ready ai people; do setup_post /api/setup/finish "{\"step\": \"$step\"}"; done
setup_post /api/setup/goal '{"goal": "streaming"}'
setup_post /api/setup/finish '{"step": "goal"}'
setup_post /api/setup/finish '{"step": "apps"}'
check "setup is at its look" until_json /api/setup '.setup.step == "theme"' 30
check "S5.7 setup's look shows aurora beside Omarchy's own (OCR)" ocr_finds success-S5.7-setup "aurora" 30
capture_console "success-S5.7-setup"
guest "agentv setup skip" >>"$RUN_DIR/input.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "home takes over${took:+ (after $took s)}" test -n "$took"

# Omarchy's desktop moves on to Gruvbox, a dark theme, as the screen's OCR
# reads light text on dark far better.
guest "OMARCHY_PATH=/usr/share/omarchy PATH=/usr/share/omarchy/bin:\$PATH omarchy-theme-set gruvbox" >>"$RUN_DIR/install.log" 2>&1 || true
check "Omarchy's desktop moves on to gruvbox, and so does the TV" until_json /api/themes '.current == "gruvbox"' 30

# Settings → Look, at aurora with the TV's keys: into the list, up to its
# first row, which is Tokyo Night, then right, to aurora.
guest "agentv screen settings look" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 2
keys right up up up up up up right
# Aurora's own box in Settings → Look: the list's first row, on the right,
# since it sorts after Tokyo Night. Tesseract reads a name in the list only
# on its own: the colour swatches beside each one throw a whole screen's
# reading off, in dark themes and light. It reads JetBrains Mono's u as a v
# at times, so "avrora" counts too.
aurora_box() {
  local shot="$RUN_DIR/.box.ppm" w h started=$SECONDS
  while (( SECONDS - started < $1 )); do
    rm -f "$shot"
    screendump "$shot"
    read -r w h < <(magick identify -format '%w %h' "$shot" 2>/dev/null)
    if [[ -n ${w:-} ]] && magick "$shot" -crop "$(( w * 26 / 100 ))x$(( h * 6 / 100 ))+$(( w * 65 / 100 ))+$(( h * 15 / 100 ))" +repage -colorspace gray -negate -resize 400% "$RUN_DIR/.box.png" 2>/dev/null; then
      tesseract "$RUN_DIR/.box.png" - --psm 7 >"$RUN_DIR/success-S5.7-settings.txt" 2>/dev/null
      grep -Eqi "a[uv]rora" "$RUN_DIR/success-S5.7-settings.txt" && return 0
    fi
    sleep 1
  done
  return 1
}
check "Settings → Look shows aurora (OCR)" aurora_box 20
capture_console "success-S5.7-settings"

# Enter, timed on the box from the key to the TV's colours and Omarchy's
# own theme both being aurora.
# shellcheck disable=SC2016
pick='start=$(date +%s%N)
agentv input key enter >/dev/null 2>&1
until curl -fsS --max-time 1 http://127.0.0.1:3000/api/theme.css 2>/dev/null | grep -qi -- "--accent: #a3be8c;" &&
  grep -qx aurora ~/.local/state/omarchy/current/theme.name 2>/dev/null; do
  (( ($(date +%s%N) - start) / 1000000 > 30000 )) && { echo 30001; exit 0; }
  sleep 0.05
done
echo $(( ($(date +%s%N) - start) / 1000000 ))'
ms=$(guest "$pick" | tail -n 1)
check "S5.7 aurora picked on the TV changes the TV and the desktop within 2 s (${ms:-?} ms)" test "${ms:-99999}" -le 2000
check "and Look says it's on" until_json /api/themes '.current == "aurora"' 10
sleep 1
capture_console "success-S5.7-aurora"
guest "journalctl --user -b --no-pager -u agentv-screen | grep -i theme | tail -n 40" >"$RUN_DIR/screen-themes.log" 2>&1 || true

stop_vm
finish
