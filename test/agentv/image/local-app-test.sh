#!/bin/bash
#
# An app built on this box, installed the supported way (ADR-039): agentv app
# install --local takes the app's folder, leaves out its fixtures, checks it
# as a local app and installs it once an adult says yes. On an installed box:
# with no PIN, --yes is the yes, and the app is in Apps on the TV within
# seconds, made by your agent; its details' "on home" puts it on an arranged
# home, and it opens from there. With the adult PIN set and no terminal, the
# TV asks for the PIN, and only the PIN typed there installs it. A folder
# that isn't a local app installs nothing, and agentv app remove takes the
# app off again.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-local-app-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-local-app-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

id=local.image-check
site=http://127.0.0.1:8768
work=/tmp/agentv-local-app

# The app's site: one page.
ssh_guest "mkdir -p $work/site && cat >$work/site/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Image check TV</title>
<body style="background:#fff;color:#000;font:28px sans-serif;margin:60px"><h1>Image check TV</h1></body>
HTML
ssh_guest "cd $work/site && (nohup python3 -m http.server 8768 --bind 127.0.0.1 >requests.log 2>&1 &)"

# make_app <version> <id>: the app's folder, as the box's agent would leave
# it, with its fixtures beside its code.
make_app() {
  ssh_guest "rm -rf $work/app && mkdir -p $work/app/fixtures/pages && cat >$work/app/manifest.json" <<JSON
{
  "schemaVersion": 1, "id": "$2", "name": "Image check", "version": "$1", "author": "agentv", "license": "MIT",
  "description": "A stand-in for an app this box built", "kinds": ["tv-app"], "entryPoints": { "tvApp": "app.ts" },
  "tv": { "contract": 1, "category": "streaming", "runtime": "web", "homeUrl": "$site/", "origins": ["$site"],
    "capabilities": ["launch"], "childSafe": true }
}
JSON
  ssh_guest "cat >$work/app/app.ts" <<APP
export default {
  id: "$2",
  async launch() {},
};
APP
  ssh_guest "cat >$work/app/fixtures/contract.json" <<'JSON'
{ "tier": "local", "routes": [], "checks": [] }
JSON
  ssh_guest "cp $work/site/index.html $work/app/fixtures/pages/home.html"
}

home() {
  ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/home" 2>/dev/null || true
}
maker() {
  jq -r --arg id "$id" '.apps[] | select(.id == $id) | .maker' <<<"$(home)" 2>/dev/null || true
}
# in_apps <seconds>: until the app is in Apps, as the daemon gives them to
# the TV.
in_apps() {
  local started=$SECONDS
  until [[ $(maker) == "made by your agent · on this tv only" ]]; do
    (( SECONDS - started < $1 )) || return 1
    sleep 0.5
  done
}
# gone <seconds>: until it isn't.
gone() {
  local started=$SECONDS
  until [[ -z $(maker) ]]; do
    (( SECONDS - started < $1 )) || return 1
    sleep 0.5
  done
}
put_layout() {
  ssh_guest "curl -s -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: application/json' -d '{\"layout\":$1}' http://127.0.0.1:3000/api/layout" 2>/dev/null || true
}
on_home() {
  [[ $(jq -r --arg id "$id" '[.layout[] | select(.id == $id)] | length' <<<"$(home)" 2>/dev/null) == "1" ]]
}
not_on_home() {
  [[ $(jq -r --arg id "$id" '[.layout[] | select(.id == $id)] | length' <<<"$(home)" 2>/dev/null) == "0" ]]
}
listed() {
  ssh_guest "agentv app list" 2>/dev/null | grep -qx "$1"
}
# The PIN pad on the TV, read off the screen, for up to <seconds>.
wait_pad() {
  local found=0
  ocr_finds "$1" "enter the adult pin" "$2" || found=1
  capture_console "$1"
  return $found
}

# Home, arranged by hand before: all apps alone. A new app isn't on it until
# its details put it there.
check "home is arranged by hand" test "$(put_layout '[{"id":"apps","x":0,"y":0,"size":"s"}]')" = "200"

# With no PIN and no terminal, --yes is the adult's yes.
make_app 1.0.0 "$id"
guest "agentv app install --local $work/app --yes; echo exit=\$?" >"$RUN_DIR/install.log" 2>&1 || true
cat "$RUN_DIR/install.log"
check "ADR-039 agentv app install --local installs the app" grep -q "^exit=0" "$RUN_DIR/install.log"
check "it said what the app can reach first" grep -q "It can reach 127.0.0.1:8768, and nothing else." "$RUN_DIR/install.log"
check "it said what it installed, and where to find it" grep -q "^Installed Image check 1.0.0 ($id). It's in Apps on the TV" "$RUN_DIR/install.log"
check "agentv app list has it as a local app" listed "$id 1.0.0 local"
# What's in its folder, as the box's own account reads it: owner, mode and
# path of each, one a line, the folder itself last.
listing="$RUN_DIR/installed-files.txt"
ssh_guest "find /var/lib/agentv/apps/$id -printf '%u %m %P\\n' | sort" >"$listing" 2>&1 || true
before=$FAILURES
check "it's in /var/lib/agentv/apps/$id, and all of it is root's" bash -c "test -s '$listing' && ! grep -qv '^root ' '$listing'"
check "its files are 644 and its folder 755" test "$(awk '{print $2, $3}' "$listing" | tr '\n' ' ')" = "644 app.ts 644 manifest.json 755  "
check "and its fixtures stayed behind" bash -c "! grep -q fixtures '$listing'"
if (( FAILURES > before )); then
  log "What the box has in /var/lib/agentv/apps/$id:"
  cat "$listing"
fi
check "ADR-039 the TV has it in Apps within 10 s, made by your agent" in_apps 10
check "and it isn't on the arranged home yet" not_on_home

# Its details' "on home" puts it on home, small in the first free cell.
check "its details' on home puts it on home" \
  test "$(put_layout "[{\"id\":\"apps\",\"x\":0,\"y\":0,\"size\":\"s\"},{\"id\":\"$id\",\"x\":1,\"y\":0,\"size\":\"s\"}]")" = "200"
check "ADR-039 it's on home" on_home

# Choosing its tile opens it, from the folder it was installed to.
guest "agentv screen app $id" >"$RUN_DIR/open.json" 2>&1 || true
check "it opens as its tile would" jq -e '.ok == true' "$RUN_DIR/open.json"
opened=0
for _ in $(seq 1 30); do
  if [[ $(front '.front.role // ""') == "web" ]] && ssh_guest "grep -q 'GET / ' $work/site/requests.log" 2>/dev/null; then
    opened=1
    break
  fi
  sleep 0.5
done
capture_console "success-local-app-open"
check "its page is in front" test "$opened" = 1
guest "agentv screen quit $id" >/dev/null 2>&1 || true
guest "agentv screen home" >/dev/null 2>&1 || true
sleep 2

# The adult PIN, set: with no terminal the TV asks for it, a cancelled pad
# installs nothing, and the PIN typed on the pad installs it.
ssh_guest "curl -fsS -X PUT -H 'Content-Type: application/json' -d '{\"pin\":\"4826\"}' http://127.0.0.1:3000/api/pin" >"$RUN_DIR/pin.json" 2>&1 || true
check "a PIN can be set" jq -e '.set == true' "$RUN_DIR/pin.json"

make_app 1.0.1 "$id"
guest "agentv app install --local $work/app --yes; echo exit=\$?" >"$RUN_DIR/install-cancel.log" 2>&1 &
asking=$!
before=$FAILURES
check "ADR-039 with the PIN set and no terminal, the TV asks for it (OCR)" wait_pad "success-local-app-pin" 40
check "the pad says it's for installing an app (OCR)" grep -Eqi "install" "$RUN_DIR/success-local-app-pin.txt"
if (( FAILURES > before )); then
  log "What OCR read on the pad:"
  cat "$RUN_DIR/success-local-app-pin.txt"
  print_screen "$RUN_DIR/.ocr.ppm"
fi
guest "agentv input key back" >"$RUN_DIR/input.log" 2>&1 || true
wait "$asking" || true
cat "$RUN_DIR/install-cancel.log"
check "cancelled on the TV, nothing is installed" grep -q "^exit=1" "$RUN_DIR/install-cancel.log"
check "and it says the PIN was needed" grep -q "Couldn't do it: that needs the adult PIN, so nothing was installed." "$RUN_DIR/install-cancel.log"
check "the app is still 1.0.0" listed "$id 1.0.0 local"

guest "agentv app install --local $work/app --yes; echo exit=\$?" >"$RUN_DIR/install-pin.log" 2>&1 &
asking=$!
wait_pad "success-local-app-pin-again" 40 || true
guest "agentv input key 4 8 2 6" >>"$RUN_DIR/input.log" 2>&1 || true
wait "$asking" || true
cat "$RUN_DIR/install-pin.log"
check "ADR-039 the PIN typed on the TV installs it" grep -q "^exit=0" "$RUN_DIR/install-pin.log"
check "the app is 1.0.1 now" listed "$id 1.0.1 local"

# A folder that isn't a local app installs nothing, and asks nobody.
make_app 1.0.0 agentv.image-check
guest "agentv app install --local $work/app --yes; echo exit=\$?" >"$RUN_DIR/install-refused.log" 2>&1 || true
cat "$RUN_DIR/install-refused.log"
check "ADR-039 a folder that isn't a local app is refused" grep -q "^exit=1" "$RUN_DIR/install-refused.log"
check "it says why" grep -q "an app built on this box has an id that starts with local., not 'agentv.image-check'" "$RUN_DIR/install-refused.log"
check "nothing of it is on the box" ssh_guest "test ! -e /var/lib/agentv/apps/agentv.image-check"

# agentv app remove takes it off, and the TV with it.
guest "agentv app remove $id; echo exit=\$?" >"$RUN_DIR/remove.log" 2>&1 || true
check "agentv app remove removes it" grep -q "^exit=0" "$RUN_DIR/remove.log"
check "its folder is gone" ssh_guest "test ! -e /var/lib/agentv/apps/$id"
check "ADR-039 and the TV's Apps drop it within 10 s" gone 10

ssh_guest "journalctl -b --no-pager -u agentv-daemon" >"$RUN_DIR/daemon.log" 2>&1 || true
stop_vm
finish
