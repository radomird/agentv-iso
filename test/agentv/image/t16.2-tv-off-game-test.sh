#!/bin/bash
#
# The TV going off leaves a game running on an installed box (ADR-084,
# T16.2). agentv screen tv off stands in for the TV's power, which a VM
# can't switch. Three things are open: an ordinary web app, Steam's stand-in
# in its stand-in gamescope (as S3.5 has them), and a stand-in for a game
# made on this TV, which is a page on home whose category is games. A fourth
# waits behind home: the same page under another name, which isn't a game.
#   - With the game in front and the TV off for the 2 minutes, the web app
#     closes, Steam and the game stay open, home shows no ambient screen over
#     the game, and the output goes off. The TV back on, the game is on the
#     screen, the same page it was. The page that isn't a game was closed:
#     opened again, it's a new page.
#   - With Steam in front, it stays in front through the same, and the game
#     stays open behind home.
# The game keeps a token it makes as its page loads and counts on a timer,
# through the app kit, so the box's daemon can say it's the same page and
# still running. A real game, real Steam and the TV's own power are the NUC's.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

GAME=local.standin
NOTES=local.notes

start_vm_from_base
wait_for_ssh 300 failure-t16.2-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-t16.2-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
wait_home 60 >/dev/null || true

wait_front() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(front '.front.role // ""') == "$1" ]] && return 0
    sleep 0.5
  done
  return 1
}

# until_status <jq filter> <seconds>: until the filter is true.
until_status() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(jq -r "$1" <<<"$(screen_status)" 2>/dev/null) == "true" ]] && return 0
    sleep 2
  done
  return 1
}

# What an app kept under a key, as the daemon on the box has it.
kept_of() {
  ssh_guest "curl -fsS --max-time 5 -H 'Content-Type: application/json' -d '{\"app\":\"$1\",\"call\":\"storage.get\",\"args\":[\"$2\"]}' http://127.0.0.1:3000/api/kit" 2>/dev/null | jq -r '.value // ""' 2>/dev/null || true
}

# What the game kept.
kept() {
  kept_of "$GAME" "$1"
}

# until_page <app> <token> <seconds>: until the app's page is another one
# than the token's, which a page that loads again is.
until_page() {
  local started=$SECONDS now
  while (( SECONDS - started < $3 )); do
    now=$(kept_of "$1" token)
    [[ -n $now && $now != "$2" ]] && return 0
    sleep 1
  done
  return 1
}

until_kept() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ -n $(kept "$1") ]] && return 0
    sleep 1
  done
  return 1
}

# The game's timer still counts: its page is open and running.
counting() {
  local before
  before=$(kept beat)
  sleep 6
  [[ -n $before && $(kept beat) -gt $before ]]
}

# Steam's stand-in and its gamescope. The bracket keeps pgrep from finding
# its own command line.
steam_running() {
  ssh_guest "pgrep -x gamescope >/dev/null && pgrep -f 'steam-stand-i[n]' >/dev/null"
}

open_ids() {
  jq -c '[.open[].id]' <<<"$(screen_status)" 2>/dev/null || true
}

# --- What's open -------------------------------------------------------------

# An ordinary app: a web page, as idle has it.
ssh_guest "mkdir -p /tmp/agentv-page && cat >/tmp/agentv-page/index.html" <"$(dirname -- "${BASH_SOURCE[0]}")/pages/media.html"
ssh_guest "cd /tmp/agentv-page && (nohup python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &)"
page=http://127.0.0.1:8765/

# Steam's app, from agentv-apps on the same owner as this clone, where an
# install from the index puts it, with the stand-ins S3.5 uses for Steam and
# gamescope, on this throwaway box only.
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
ssh_sudo "install -d -m 755 /var/lib/agentv/apps/agentv.steam"
for file in manifest.json app.ts; do
  ssh_guest "cat >/tmp/$file" <"$apps/apps/steam/$file"
  ssh_sudo "install -m 644 /tmp/$file /var/lib/agentv/apps/agentv.steam/$file"
done
ssh_sudo "record=/var/lib/agentv/apps/installed.json; [[ -f \$record ]] || echo '{}' >\$record; jq --arg commit '$commit' --arg repo 'https://github.com/$owner/agentv-apps' '. + {\"agentv.steam\": {id: \"agentv.steam\", name: \"Steam\", version: \"1.0.0\", tier: \"official\", repo: \$repo, commit: \$commit, path: \"apps/steam\", installedAt: (now | todate)}}' \$record >\$record.new && chmod 644 \$record.new && mv \$record.new \$record"
ssh_guest "cat >/tmp/steam" <<'STEAM'
#!/bin/bash
# A stand-in for Steam in AgenTV's image checks: a full-screen window, drawn
# without a GPU, until /tmp/agentv-steam-quit appears or it's stopped. mpv
# draws it in shared memory; if that doesn't stay up, Chromium draws it.
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
# A stand-in for gamescope, which needs a GPU: it runs what comes after --,
# and ends when that does, as gamescope does.
while (( $# > 0 )) && [[ $1 != "--" ]]; do shift; done
shift
"$@"
GAMESCOPE
ssh_sudo "install -m 755 /tmp/steam /usr/bin/steam && install -m 755 /tmp/gamescope /usr/bin/gamescope"

# The game: a page of its own, category games, as the game recipe makes one.
ssh_guest "rm -rf /tmp/standin && mkdir -p /tmp/standin && cat >/tmp/standin/manifest.json" <<'MANIFEST'
{
  "schemaVersion": 1,
  "id": "local.standin",
  "name": "Standin",
  "version": "1.0.0",
  "author": "your agent",
  "license": "MIT",
  "description": "A stand-in game for the TV off image check",
  "kinds": ["tv-app"],
  "entryPoints": { "page": "index.html" },
  "tv": { "contract": 2, "category": "games", "runtime": "page", "capabilities": ["launch"] }
}
MANIFEST
ssh_guest "cat >/tmp/standin/index.html" <<'PAGE'
<!doctype html>
<html><head><link rel="stylesheet" href="style.css"></head>
<body><p>level seven</p><script src="/_agentv/kit.js"></script><script src="game.js"></script></body></html>
PAGE
ssh_guest "cat >/tmp/standin/style.css" <<'STYLE'
body { margin: 0; background: #1a1b26; color: #c0caf5; font: 120px monospace; }
p { margin: 96px; }
STYLE
ssh_guest "cat >/tmp/standin/game.js" <<'GAME'
const kit = window.agentv;
(async () => {
  // Made once as the page loads: a page that loads again has another.
  await kit.storage.set("token", String(Date.now()) + "-" + String(Math.random()).slice(2, 8));
  let beat = 0;
  await kit.storage.set("beat", beat);
  setInterval(() => void kit.storage.set("beat", ++beat), 2000);
  kit.onPause(() => void kit.storage.set("paused", "yes"));
  kit.onResume(() => void kit.storage.set("paused", "no"));
  kit.ready();
})();
GAME
ssh_sudo "agentv app install --local /tmp/standin --yes" >"$RUN_DIR/install.log" 2>&1 || true
on_home() {
  local started=$SECONDS
  while (( SECONDS - started < 30 )); do
    [[ $(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/home" 2>/dev/null | jq -r --arg id "$GAME" '[.apps[] | select(.id == $id) | .category] == ["games"]' 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 1
}
check "home has the stand-in game, as a game" on_home

# The same page as an app that isn't a game.
ssh_guest "rm -rf /tmp/notes && cp -r /tmp/standin /tmp/notes && sed -i -e 's/local.standin/local.notes/' -e 's/\"Standin\"/\"Notes\"/' -e 's/\"games\"/\"utility\"/' /tmp/notes/manifest.json"
ssh_sudo "agentv app install --local /tmp/notes --yes" >"$RUN_DIR/install-notes.log" 2>&1 || true

guest "agentv screen open $page" >>"$RUN_DIR/screen.log" 2>&1 || true
check "the ordinary app opens in front" wait_front web 60
guest "agentv screen home" >>"$RUN_DIR/screen.log" 2>&1 || true
wait_front home 10 || true
guest "agentv screen app agentv.steam" >>"$RUN_DIR/screen.log" 2>&1 || true
check "Steam's stand-in opens in front, in its gamescope" wait_front steam 90
check "and it runs" steam_running
guest "agentv screen home" >>"$RUN_DIR/screen.log" 2>&1 || true
check "home is in front again" wait_front home 10
guest "agentv screen app $NOTES" >"$RUN_DIR/open-notes.log" 2>&1 || true
check "the page app that isn't a game opens on home" until_page "$NOTES" "" 30
notes=$(kept_of "$NOTES" token)
log "The other page is $notes"
guest "agentv screen home" >>"$RUN_DIR/screen.log" 2>&1 || true
guest "agentv screen app $GAME" >"$RUN_DIR/open.log" 2>&1 || true
check "the game opens the way its tile would, on home" grep -q '"ok": *true' "$RUN_DIR/open.log"
check "and its page runs" until_kept token 30
token=$(kept token)
log "The game's page is $token"
check "the web app and Steam are open behind it" test "$(open_ids)" = "[\"$page\",\"agentv.steam\"]"
check "the game is on the TV (OCR)" ocr_finds success-t16.2-game 'level.?seven' 15
capture_console "success-t16.2-game"

# --- The TV goes off with the game in front ------------------------------------

guest "agentv screen idle-after off" >>"$RUN_DIR/screen.log" 2>&1 || true
guest "agentv screen tv off" >>"$RUN_DIR/screen.log" 2>&1 || true
log "Waiting out the 2 minutes, with the game in front"
check "T16.2 after 2 minutes the ordinary app is closed, and Steam isn't" until_status '[.open[].id] == ["agentv.steam"]' 150
check "T16.2 and the TV's output goes off" until_status '.output == "off"' 30
screen_status >"$RUN_DIR/status-off-game.json"
check "T16.2 Steam's stand-in still runs" steam_running
check "T16.2 no ambient screen over the game" jq -e '.ambient == false and .front.role == "home"' "$RUN_DIR/status-off-game.json"
check "T16.2 the game is the same page as before" test "$(kept token)" = "$token"
check "T16.2 it was never told to pause" test "$(kept paused)" = ""
check "T16.2 and it still runs" counting

guest "agentv screen tv on" >>"$RUN_DIR/screen.log" 2>&1 || true
check "T16.2 the TV back on, the output is on" until_status '.output == "on" and .tv == "on"' 20
check "T16.2 and the TV is back on the game, not the ambient screen (OCR)" ocr_finds success-t16.2-back 'level.?seven' 20
capture_console "success-t16.2-back"
check "the ambient screen never came" test "$(front '.ambient')" = "false"
check "the game is still the same page" test "$(kept token)" = "$token"

# The page app that isn't a game closed with the others: its tile opens a
# new page, where one left open would come back as it was.
check "the page app that isn't a game is still the page it was, until it's opened" test "$(kept_of "$NOTES" token)" = "$notes"
guest "agentv screen home" >>"$RUN_DIR/screen.log" 2>&1 || true
guest "agentv screen app $NOTES" >>"$RUN_DIR/open-notes.log" 2>&1 || true
check "the page app that isn't a game was closed: opened again, it's a new page" until_page "$NOTES" "$notes" 30
check "and the game beside it is still the same page" test "$(kept token)" = "$token"

# --- The TV goes off with Steam in front ----------------------------------------

guest "agentv screen open $page" >>"$RUN_DIR/screen.log" 2>&1 || true
check "the ordinary app opens again" wait_front web 60
guest "agentv screen app agentv.steam" >>"$RUN_DIR/screen.log" 2>&1 || true
check "Steam comes in front again" wait_front steam 15
guest "agentv screen tv off" >>"$RUN_DIR/screen.log" 2>&1 || true
log "Waiting out the 2 minutes, with Steam in front"
check "T16.2 after 2 minutes the ordinary app is closed again, and Steam isn't" until_status '[.open[].id] == ["agentv.steam"]' 150
check "T16.2 and the output goes off" until_status '.output == "off"' 30
screen_status >"$RUN_DIR/status-off-steam.json"
check "T16.2 Steam is still in front, with no ambient screen" jq -e '.ambient == false and .front.role == "steam"' "$RUN_DIR/status-off-steam.json"
check "T16.2 Steam's stand-in still runs" steam_running
check "T16.2 the game is still open behind home, the same page" test "$(kept token)" = "$token"
guest "agentv screen tv on" >>"$RUN_DIR/screen.log" 2>&1 || true
check "T16.2 the TV back on, the output is on" until_status '.output == "on" and .tv == "on"' 20
check "T16.2 and Steam is in front" test "$(front '[.front.role, .ambient] | map(tostring) | join(" ")')" = "steam false"
capture_console "success-t16.2-steam"

# Nothing of the stand-ins is left behind.
guest "agentv screen quit agentv.steam" >>"$RUN_DIR/screen.log" 2>&1 || true
ssh_sudo "agentv app remove $GAME" >"$RUN_DIR/remove.log" 2>&1 || true
ssh_sudo "agentv app remove $NOTES" >>"$RUN_DIR/remove.log" 2>&1 || true

guest "journalctl --user -b --no-pager -u agentv-screen -u agentv-toast" >"$RUN_DIR/t16.2.log" 2>&1 || true
stop_vm
finish
