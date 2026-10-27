#!/bin/bash
#
# S3.5: Steam opens full screen and returns to the home screen on quit. Steam's
# app, agentv.steam from agentv-apps, goes on the box where an install from the
# index puts it, and opening it starts Steam the box's own way: Steam Big
# Picture in a gamescope of its own, at the TV's mode (ADR-031). Home keeps the
# game running behind it, with Quit on its tile (S2.15), and quitting Steam
# brings home back.
#
# Steam itself needs an account, downloads its runtime from Valve on first
# start and draws its UI on a GPU, none of which a CI box has. So a stand-in
# called steam shows a full-screen window until it's asked to quit, as Exit
# Steam does. gamescope needs a GPU too: on Mesa's software Vulkan it crashes
# in libvulkan_lvp.so. So gamescope has a stand-in as well, which notes how
# the screen daemon started it and runs what comes after its --. The screen
# daemon knows Steam's window as one from the gamescope it started, so the
# rest is the box's own. Steam's own sign-in screen full screen in its real
# gamescope is S1.5, on the NUC.
#
# Steam's tile shows the icon Steam's package installs, found through its
# desktop entry the way the desktop's app launcher finds it. Here that's a
# stand-in desktop entry and a plain magenta square where the package would
# put them, never Valve's own file.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-s3.5-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-s3.5-no-tv"; check "the TV session came up" false; stop_vm; finish; }

# How much of the screen is the stand-in icon's magenta.
magenta() {
  magick "$1" -fuzz 6% -fill black +opaque "#ff00ff" -fill white -opaque "#ff00ff" -format '%[fx:int(mean*w*h)]' info: 2>/dev/null || echo 0
}
capture_console "success-S3.5-before"
before=$(magenta "$RUN_DIR/success-S3.5-before.png")

# What Steam's package installs for its icon: its desktop entry and its icon
# in the hicolor theme, as stand-ins, on this throwaway box only.
magick -size 256x256 xc:"#ff00ff" "$RUN_DIR/steam-icon.png"
ssh_guest "cat >/tmp/steam.png" <"$RUN_DIR/steam-icon.png"
ssh_guest "cat >/tmp/steam.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Steam stand-in
Exec=/usr/bin/steam %U
Icon=steam
Type=Application
DESKTOP
ssh_sudo "install -D -m 644 /tmp/steam.png /usr/share/icons/hicolor/256x256/apps/steam.png && install -D -m 644 /tmp/steam.desktop /usr/share/applications/steam.desktop"

# Steam's app, from agentv-apps on the same owner as this clone.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
owner=${AGENTV_TEST_OWNER:-$(sed -n 's#.*url = https://github.com/\([^/]*\)/.*#\1#p' "$here/.git/config" 2>/dev/null | head -n 1)}
ref=${AGENTV_TEST_APPS_REF:-main}
apps="$RUN_DIR/agentv-apps"
mkdir -p "$apps"
got_app() {
  curl -fsSL --retry 3 "https://codeload.github.com/$owner/agentv-apps/tar.gz/$ref" -o "$RUN_DIR/agentv-apps.tar.gz" &&
    tar -xzf "$RUN_DIR/agentv-apps.tar.gz" -C "$apps" --strip-components=1 &&
    [[ -f $apps/apps/steam/manifest.json ]]
}
check "Steam's app comes from $owner/agentv-apps at $ref" got_app
commit=$(python3 -c 'import sys, tarfile; print(tarfile.open(sys.argv[1]).pax_headers.get("comment", ""))' "$RUN_DIR/agentv-apps.tar.gz" 2>/dev/null || true)

# Where an install from the index puts it: its folder without its fixtures,
# and its record as an official app.
ssh_sudo "install -d -m 755 /var/lib/agentv/apps/agentv.steam"
for file in manifest.json app.ts; do
  ssh_guest "cat >/tmp/$file" <"$apps/apps/steam/$file"
  ssh_sudo "install -m 644 /tmp/$file /var/lib/agentv/apps/agentv.steam/$file"
done
ssh_sudo "record=/var/lib/agentv/apps/installed.json; [[ -f \$record ]] || echo '{}' >\$record; jq --arg commit '$commit' --arg repo 'https://github.com/$owner/agentv-apps' '. + {\"agentv.steam\": {id: \"agentv.steam\", name: \"Steam\", version: \"1.0.0\", tier: \"official\", repo: \$repo, commit: \$commit, path: \"apps/steam\", installedAt: (now | todate)}}' \$record >\$record.new && chmod 644 \$record.new && mv \$record.new \$record"
check "Steam's app is on home's list of apps" \
  ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/home | jq -e '.apps[] | select(.id == \"agentv.steam\")' >/dev/null"
check "S3.5 Steam's tile has the icon Steam's package gives it" \
  ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/home | jq -e '.apps[] | select(.id == \"agentv.steam\") | .icon == \"/api/apps/agentv.steam/icon\"' >/dev/null"
served_icon() {
  [[ $(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/apps/agentv.steam/icon | sha256sum" 2>/dev/null | cut -d' ' -f1) == "$(sha256sum <"$RUN_DIR/steam-icon.png" | cut -d' ' -f1)" ]]
}
check "S3.5 the daemon serves that icon as the package put it" served_icon
# And home draws it on Steam's tile: a block of the stand-in's magenta that
# wasn't on the screen before. A logo is 72 px square.
after=0
tile_icon() {
  local started=$SECONDS
  while (( SECONDS - started < 20 )); do
    capture_console "success-S3.5-tile"
    after=$(magenta "$RUN_DIR/success-S3.5-tile.png")
    (( after - before >= 1000 )) && return 0
    sleep 1
  done
  return 1
}
shown=no
tile_icon && shown=yes
check "S3.5 home shows the icon on Steam's tile" test "$shown" = yes
# When it doesn't, what home had and showed, in the run's own log: the
# magenta, home's tiles, what was in front, and the screen in colour, small.
if [[ $shown != yes ]]; then
  log "magenta pixels: $before before, $after after"
  log "home's tiles: $(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/home" 2>/dev/null | jq -c '[.layout[] | "\(.id) \(.size)@\(.x),\(.y)"]' 2>/dev/null)"
  log "in front: $(front '.front.role // ""')"
  log "The screen, in colour, as a base64 PNG:"
  magick "$RUN_DIR/success-S3.5-tile.png" -resize 640x -colors 64 png:- 2>/dev/null | base64 -w 120
  log "End of the screen"
fi

# The stand-ins, where Steam's and gamescope's own packages put them, on
# this throwaway box only.
ssh_guest "cat >/tmp/steam" <<'STEAM'
#!/bin/bash
# A stand-in for Steam in AgenTV's S3.5 image check: a full-screen window,
# drawn without a GPU, until /tmp/agentv-steam-quit appears, as Exit Steam
# does. mpv draws it in shared memory; if that doesn't stay up, Chromium
# draws it instead.
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
# A stand-in for gamescope in AgenTV's S3.5 image check, which has no GPU:
# it notes how it was started and runs what comes after --, and it ends when
# that does, as gamescope does.
printf '%s\n' "$*" >/tmp/agentv-gamescope-args
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
    sleep 0.5
  done
  return 1
}

# Whether Steam is in front and fills the screen.
fills_screen() {
  local address monitor client
  [[ $(front '.front.role // ""') == "steam" ]] || return 1
  address=$(front '.front.address // ""')
  monitor=$(guest_hyprctl "-j monitors" 2>/dev/null | jq -c '.[0] | [(.width / .scale | floor), (.height / .scale | floor)]' 2>/dev/null || true)
  client=$(guest_hyprctl "-j clients" 2>/dev/null | jq -c --arg address "$address" '.[] | select(.address == $address) | {at, size}' 2>/dev/null || true)
  echo "monitor $monitor, window $client" >>"$RUN_DIR/geometry.log"
  [[ -n $client ]] && jq -e --argjson monitor "${monitor:-null}" '$monitor != null and .at == [0, 0] and .size == $monitor' <<<"$client" >/dev/null
}

# The game running behind home: gamescope and the stand-in's window. The
# bracket keeps pgrep from finding its own command line.
game_running() {
  ssh_guest "pgrep -x gamescope >/dev/null && pgrep -f 'steam-stand-i[n]' >/dev/null"
}

# What the screen daemon and gamescope said, in the run's own log, for when
# Steam doesn't come up.
said() {
  log "agentv screen app said: $(tail -n 1 "$RUN_DIR/screen.log")"
  guest "journalctl --user -b --no-pager -u agentv-screen | grep -iE 'steam|gamescope|mpv|chromium' | grep -v '^ *#' | tail -n 25" 2>/dev/null |
    while IFS= read -r line; do log "screen daemon: $line"; done
}

guest "agentv screen app agentv.steam" >>"$RUN_DIR/screen.log" 2>&1 || true
up=no
wait_front steam 90 && up=yes
check "S3.5 Steam opens in front, in its gamescope" test "$up" = yes
[[ $up == yes ]] || said
sleep 3
check "S3.5 it fills the screen" fills_screen
# How the screen daemon started gamescope: full screen, at the TV's mode,
# with Steam's Big Picture.
mode=$(guest_hyprctl "-j monitors" 2>/dev/null | jq -r '.[0] | "-W \(.width) -H \(.height)"' 2>/dev/null || true)
started=$(ssh_guest "cat /tmp/agentv-gamescope-args" 2>/dev/null || true)
log "gamescope was started with: $started"
started_right() {
  [[ -n $mode && " $started " == *" -f "* && " $started " == *" $mode "* && $started == *"-- steam -gamepadui" ]]
}
check "S3.5 Steam starts in gamescope, full screen at the TV's mode ($mode), as Big Picture" started_right
capture_console "success-S3.5-steam"
guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen-daemon.log" 2>&1 || true

# Home keeps it running behind it, as a game, and opening it again brings
# the same one back.
guest "agentv screen home" >>"$RUN_DIR/screen.log" 2>&1 || true
check "S2.15 Home shows the home screen" wait_front home 10
check "S2.15 S3.5 the game keeps running behind home" game_running
check "S2.15 home lists Steam as a game that's open, which its tile offers to quit" \
  test "$(jq -c '[.open[] | select(.id == "agentv.steam") | .role]' <<<"$(screen_status)" 2>/dev/null)" = '["steam"]'
guest "agentv screen app agentv.steam" >>"$RUN_DIR/screen.log" 2>&1 || true
check "S3.5 opening it again brings the same Steam back" wait_front steam 15

# Quitting Steam, as Exit Steam does, brings home back.
ssh_guest "touch /tmp/agentv-steam-quit"
check "S3.5 quitting Steam brings the home screen back" wait_front home 30
check "S3.5 and nothing of Steam is left running" ssh_guest "! pgrep -x gamescope >/dev/null"
capture_console "success-S3.5-home"

# Quit on its tile, from home, closes it too.
guest "agentv screen app agentv.steam" >>"$RUN_DIR/screen.log" 2>&1 || true
wait_front steam 60 || true
guest "agentv screen home" >>"$RUN_DIR/screen.log" 2>&1 || true
wait_front home 10 || true
guest "agentv screen quit agentv.steam" >>"$RUN_DIR/screen.log" 2>&1 || true
gone() {
  local started=$SECONDS
  while (( SECONDS - started < 30 )); do
    ssh_guest "! pgrep -x gamescope >/dev/null" && return 0
    sleep 0.5
  done
  return 1
}
check "S2.15 Quit on its tile closes Steam, and home stays" gone
check "home is still in front" wait_front home 5

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen-daemon.log" 2>&1 || true
stop_vm
finish
