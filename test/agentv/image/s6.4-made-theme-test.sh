#!/bin/bash
#
# S6.4 on an installed box: a theme your agent made, from an adult's yes to
# the TV and the desktop. The builder's part, the agent and its theme check,
# is played by a theme as theme_check leaves it: its colours, its icon set,
# a scene drawn as a picture and its preview. Root's hand-over installs the
# approved build into /var/lib/agentv/themes, checked again; the daemon asks
# the screen daemon, which runs as the owner, to hand it to Omarchy as a
# theme of theirs and set it; and the TV and the desktop both turn to it.
# Then a build that changed after its gate isn't put in place, and removing
# the theme takes it from Omarchy too. "A calm forest at dusk" from one
# sentence, with Claude, is the NUC's (S6.4).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

ID=local.theme-calm-forest
NAME=calm-forest
BUILDS=/var/lib/agentv/build
THEMES=/var/lib/agentv/themes
STATE=/var/lib/private/agentv/daemon
DROP=$STATE/build-drop
RUN=/run/agentv-build

# until_true <seconds> <command...>: until the command succeeds.
until_true() {
  local started=$SECONDS limit=$1
  shift
  while (( SECONDS - started < limit )); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

start_vm_from_base
wait_for_ssh 300 failure-S6.4-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
wait_home 60 >/dev/null || true

# A version as the builder leaves it once its gate passed: the theme, and
# its status, waiting for an adult's yes.
picture=$(magick -size 384x216 xc:'#2f3d36' png:- | base64 -w0)
built() { # <version> <build>
  local dir=$BUILDS/$ID/$1
  ssh_guest "sudo install -d $dir/work/theme/backgrounds" &&
    ssh_guest "sudo tee $dir/work/theme/colors.toml >/dev/null" <<'COLORS'
mode = "dark"
accent = "#e0a458"
selection = "#2f3d36"
muted = "#4a5a52"
background = "#141c1a"
dark_background = "#0f1513"
darker_background = "#0a0f0d"
lighter_background = "#1e2a26"
foreground = "#d8d4c3"
dark_foreground = "#8a9a8f"
light_foreground = "#e4e0cf"
bright_foreground = "#f2eedc"
red = "#d0705a"
yellow = "#e0c069"
orange = "#e0a458"
green = "#8fb573"
cyan = "#6fb3a8"
blue = "#7c9fc4"
magenta = "#b48ead"
brown = "#8a6a4a"
bright_red = "#e88a74"
bright_yellow = "#f0d488"
bright_green = "#a8cc8c"
bright_cyan = "#8cc8be"
bright_blue = "#98b6d6"
bright_magenta = "#c8a4c2"
COLORS
  ssh_guest "echo Yaru-sage | sudo tee $dir/work/theme/icons.theme >/dev/null"
  ssh_guest "echo '<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 16 9\"><rect width=\"16\" height=\"9\" fill=\"#2f3d36\"/></svg>' | sudo tee $dir/work/theme/backgrounds/1-scene.svg >/dev/null"
  ssh_guest "echo $picture | base64 -d | sudo tee $dir/work/theme/backgrounds/1-scene.png >/dev/null"
  ssh_guest "echo $picture | base64 -d | sudo tee $dir/work/theme/preview.png >/dev/null"
  ssh_guest "printf '%s' '{\"build\":\"$2\",\"id\":\"$ID\",\"version\":\"$1\",\"phase\":\"build\",\"state\":\"approve\",\"steps\":[],\"understood\":{\"name\":\"Calm forest\",\"recipe\":\"theme\",\"says\":\"A calm forest at dusk\"},\"started\":\"\",\"at\":\"$(date -u +%FT%TZ)\"}' | sudo tee $dir/status.json >/dev/null"
}
# The daemon's record of what was asked, as it keeps it.
ssh_guest "printf '%s' '[{\"build\":\"b1\",\"id\":\"$ID\",\"version\":\"1.0.0\",\"sentence\":\"a theme: a calm forest at dusk\",\"provider\":\"claude\",\"path\":\"key\",\"at\":\"$(date -u +%FT%TZ)\"}]' | sudo tee $STATE/builds.json >/dev/null"
built 1.0.0 b1

# The adult's yes, as the daemon drops it.
ssh_guest "sudo install -d -m 700 $DROP && printf '%s' '{\"build\":\"b1\",\"id\":\"$ID\",\"version\":\"1.0.0\"}' | sudo tee $DROP/install.json >/dev/null"
installed() { [[ $(ssh_guest "sudo jq -r .state $BUILDS/$ID/1.0.0/status.json") == installed ]]; }
check "root's hand-over installed the approved theme" until_true 60 installed
ssh_guest "sudo cat $RUN/answer.json" >"$RUN_DIR/answer.json" 2>&1 || true
ssh_guest "cd $THEMES/$ID && sudo find . -printf '%P %m\n' | LC_ALL=C sort" >"$RUN_DIR/placed.txt" 2>&1 || true
# Compared in bash: the test's container has no diff.
placed_is() { [[ $(<"$RUN_DIR/placed.txt") == "$(printf '%s\n' ' 755' 'about.json 644' 'backgrounds 755' 'backgrounds/1-scene.png 644' 'colors.toml 644' 'icons.theme 644' 'preview.png 644')" ]]; }
check "with only what Omarchy shows, for anyone to read" placed_is

# The screen daemon, as the owner, hands it to Omarchy and sets it.
mine() { guest "test \"\$(cat ~/.config/omarchy/themes/$NAME/.agentv-theme)\" = $ID && test -f ~/.config/omarchy/themes/$NAME/colors.toml"; }
current() { [[ $(guest "cat ~/.local/state/omarchy/current/theme.name") == "$NAME" ]]; }
tv_has() { ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/theme.css | grep -qi -- '--background: #141c1a;'"; }
check "S6.4 the screen daemon handed it to Omarchy as a theme of the owner's" until_true 90 mine
check "S6.4 the desktop has it: it's Omarchy's theme now" until_true 90 current
check "S6.4 and the TV has its colours" until_true 30 tv_has
background() { [[ $(guest "basename \"\$(readlink -f ~/.local/state/omarchy/current/background)\"") == 1-scene.png ]]; }
check "and Omarchy's background is the theme's own picture" until_true 30 background
# Look lists it once the screen daemon says Omarchy has it, which is once
# omarchy-theme-set is done, a few seconds after the desktop shows it.
looks() {
  ssh_guest "curl -fsS http://127.0.0.1:3000/api/themes" >"$RUN_DIR/themes.json" 2>&1 &&
    jq -e '.current == "calm-forest" and ([.themes[] | select(.note == "made by your agent") | .id] == ["calm-forest"])' "$RUN_DIR/themes.json"
}
check "Look lists it after Omarchy's own, made by your agent" until_true 30 looks
sleep 2
capture_console "success-S6.4-theme"

# A version that changed after its gate passed isn't put in place.
ssh_guest "sudo jq '. + [{\"build\":\"b2\",\"id\":\"$ID\",\"version\":\"1.1.0\",\"sentence\":\"a theme: a calm forest at dusk\",\"provider\":\"claude\",\"path\":\"key\",\"at\":\"$(date -u +%FT%TZ)\"}]' $STATE/builds.json | sudo tee $STATE/builds.next >/dev/null && sudo mv $STATE/builds.next $STATE/builds.json"
built 1.1.0 b2
ssh_guest "echo \"os.execute('id')\" | sudo tee $BUILDS/$ID/1.1.0/work/theme/hyprland.lua >/dev/null"
ssh_guest "printf '%s' '{\"build\":\"b2\",\"id\":\"$ID\",\"version\":\"1.1.0\"}' | sudo tee $DROP/install.json >/dev/null"
refused() { ssh_guest "sudo jq -e '.build == \"b2\" and .started == false' $RUN/answer.json"; }
check "a theme that changed after its gate isn't installed" until_true 60 refused
ssh_guest "sudo cat $RUN/answer.json" >"$RUN_DIR/refused.json" 2>&1 || true
check "it says why: what it holds that a theme doesn't" jq -e '.reason | test("hyprland\\.lua isn.t something a theme here holds")' "$RUN_DIR/refused.json"
check "and the theme in place is still the one approved" ssh_guest "! sudo test -e $THEMES/$ID/hyprland.lua && sudo grep -q '\"version\":\"1.0.0\"' $THEMES/$ID/about.json"

# Removed, it goes from the box and from Omarchy.
ssh_guest "printf '%s' '{\"id\":\"$ID\"}' | sudo tee $DROP/remove.json >/dev/null"
gone() { ssh_guest "! sudo test -e $THEMES/$ID" && guest "! test -e ~/.config/omarchy/themes/$NAME"; }
check "removing it takes it from the box, and from Omarchy's themes" until_true 90 gone

ssh_guest "sudo journalctl -b --no-pager -u agentv-build.service -u agentv-daemon.service | grep -i theme" >"$RUN_DIR/journal.log" 2>&1 || true
guest "journalctl --user -b --no-pager -u agentv-screen | grep -i theme" >>"$RUN_DIR/journal.log" 2>&1 || true

stop_vm
finish
