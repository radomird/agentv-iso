#!/bin/bash
#
# A page app on an installed box (ADR-043, the runtime S6.6 and S6.7 build
# on, and S6.8's parts here). A small probe app, installed from a folder as
# a local app, opens the way its tile would. Home shows it in a frame on its
# own origin, and the app reaches the box through the app kit: it keeps
# something in its own storage, sets its tile, and tries a site it didn't
# declare, which its policy refuses. Then it sends its own frame to that
# site, which home's filter refuses, and home closes it.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

APP=local.probe

# kit <call> [<args json>]: one of the probe's kit calls, as home relays
# them, asked of the daemon on the box.
kit() {
  ssh_guest "curl -fsS --max-time 5 -H 'Content-Type: application/json' -d '{\"app\":\"$APP\",\"call\":\"$1\",\"args\":${2:-[]}}' http://127.0.0.1:3000/api/kit" 2>/dev/null || true
}

# until_kit <key> <seconds>: until the probe has kept something under key.
until_kit() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(kit storage.get "[\"$1\"]" | jq -r '.value != null' 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 1
}

start_vm_from_base
wait_for_ssh 300 failure-S6.6-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "setup skipped, home is in front${took:+ (after $took s)}" test -n "$took"

# The probe: a page of its own and the kit, nothing else.
ssh_guest "rm -rf /tmp/probe && mkdir -p /tmp/probe && cat >/tmp/probe/manifest.json" <<'MANIFEST'
{
  "schemaVersion": 1,
  "id": "local.probe",
  "name": "Probe",
  "version": "1.0.0",
  "author": "your agent",
  "license": "MIT",
  "description": "A probe for the page runtime's image check",
  "kinds": ["tv-app"],
  "entryPoints": { "page": "index.html" },
  "tv": { "contract": 2, "category": "utility", "runtime": "page", "capabilities": ["launch", "tile"], "tiles": { "s": "logo", "m": "probe" } }
}
MANIFEST
ssh_guest "cat >/tmp/probe/index.html" <<'PAGE'
<!doctype html>
<html><body><p>probe</p><script src="/_agentv/kit.js"></script><script src="probe.js"></script></body></html>
PAGE
ssh_guest "cat >/tmp/probe/probe.js" <<'PROBE'
const kit = window.agentv;
(async () => {
  await kit.storage.set("opened", { at: Date.now(), origin: String(origin), host: location.host });
  await kit.tile.set({ headline: { label: "probe", value: "ok" } });
  // A site it doesn't declare, put together as it runs: the contract's own
  // check refuses one written out, before the app ever runs.
  const away = ["https:", "", "example.org", ""].join("/");
  let reach = "refused";
  try { await fetch(away); reach = "reached"; } catch {}
  await kit.storage.set("reach", reach);
  kit.ready();
  setTimeout(() => { location.href = away; }, 1500);
})();
PROBE

ssh_sudo "agentv app install --local /tmp/probe --yes" >"$RUN_DIR/install.log" 2>&1 || true
check "the probe installs from its folder as a local app" ssh_guest "agentv app list | grep -q '$APP'"
page=$(ssh_guest "curl -fsS -D - --max-time 5 -H 'Host: $APP.app.localhost:3000' http://127.0.0.1:3000/" 2>/dev/null || true)
printf '%s\n' "$page" >"$RUN_DIR/page.txt"
check "its own origin serves its page, under the policy the box writes" grep -qi "^content-security-policy: default-src 'none'" "$RUN_DIR/page.txt"
check "and that origin isn't the daemon's" test "$(ssh_guest "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: $APP.app.localhost:3000' http://127.0.0.1:3000/api/home")" = "404"

# Home lists it once root's install has told the daemon, as its tile shows.
on_home() {
  local started=$SECONDS
  while (( SECONDS - started < 30 )); do
    [[ $(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/home" 2>/dev/null | jq -r --arg id "$APP" '[.apps[].id] | index($id) != null' 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 1
}
check "home has it" on_home
guest "agentv screen app $APP" >"$RUN_DIR/open.log" 2>&1 || true
check "it opens the way its tile would, on home" grep -q '"ok": *true' "$RUN_DIR/open.log"
check "the app reached the box through the kit, from its own origin" until_kit opened 30
opened=$(kit storage.get '["opened"]')
printf '%s\n' "$opened" >"$RUN_DIR/opened.json"
check "its frame's origin is opaque, and its page came from $APP.app.localhost" jq -e '.value.origin == "null" and (.value.host | startswith("local.probe.app.localhost"))' "$RUN_DIR/opened.json"
check "S6.8 a site it didn't declare is refused" test "$(kit storage.get '["reach"]' | jq -r .value)" = "refused"
check "its tile on home is what it set" test "$(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/tile/$APP/m" | jq -r .tile.headline.value)" = "ok"
check "home is still in front, with the app in its frame" test "$(front '.front.role // ""')" = "home"
sleep 4
ssh_guest "journalctl -b --no-pager -u agentv-daemon" >"$RUN_DIR/daemon.log" 2>&1 || true
check "S6.8 sending its frame to that site, home's filter refuses it" grep -q "home's proxy: refused CONNECT example.org:443" "$RUN_DIR/daemon.log"

ssh_sudo "agentv app remove $APP" >"$RUN_DIR/remove.log" 2>&1 || true
check "the probe is gone after" ssh_guest "test ! -e /var/lib/agentv/apps/$APP"

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen.log" 2>&1 || true
stop_vm
finish
