#!/bin/bash
#
# A service's own profiles for who's watching (ADR-009) on an installed box.
# A stand-in service with a profile picker, and an app for it with profiles,
# installed with agentv app install --local. The first time an adult opens
# it, it lists the service's profiles for the daemon; an adult picks the one
# for children. Then a child starting to watch with the app open, and the
# app opened by a child, each open that profile, and an adult opening it
# again leaves the service's profile as it is.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-child-profile-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-child-profile-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

id=local.profile-check
site=http://127.0.0.1:8769
work=/tmp/agentv-profile-check
PIN=4826

# The service: who's watching, and a page for each profile.
ssh_guest "mkdir -p $work/site/as && cat >$work/site/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Who's watching?</title>
<body style="background:#fff;color:#000;font:28px sans-serif;margin:60px"><h1>Who's watching?</h1>
<button class="profile">Radomir</button> <button class="profile">Kids</button></body>
HTML
for name in radomir kids; do
  ssh_guest "printf '%s\n' '<!doctype html><meta charset=\"utf-8\"><title>$name</title><h1>$name</h1>' >$work/site/as/$name.html"
done
ssh_guest "cd $work/site && (nohup python3 -m http.server 8769 --bind 127.0.0.1 >requests.log 2>&1 &)"

# The app: it lists the profiles on the picker, and opens one by its page.
ssh_guest "mkdir -p $work/app && cat >$work/app/manifest.json" <<JSON
{
  "schemaVersion": 1, "id": "$id", "name": "Profile check", "version": "1.0.0", "author": "agentv", "license": "MIT",
  "description": "A stand-in for a streaming service with profiles", "kinds": ["tv-app"], "entryPoints": { "tvApp": "app.ts" },
  "tv": { "contract": 1, "category": "streaming", "runtime": "web", "homeUrl": "$site/", "origins": ["$site"],
    "capabilities": ["launch", "profiles"], "childSafe": false }
}
JSON
ssh_guest "cat >$work/app/app.ts" <<'APP'
export default {
  id: "local.profile-check",
  async launch() {},
  profiles: {
    async list(ctx) {
      return ctx.page.evaluate(() => [...document.querySelectorAll(".profile")].map((button) => button.textContent.trim()));
    },
    async select(ctx, name) {
      await ctx.page.goto(`http://127.0.0.1:8769/as/${encodeURIComponent(name.toLowerCase())}.html`);
    },
  },
};
APP
guest "agentv app install --local $work/app --yes" >"$RUN_DIR/install.log" 2>&1 || true
check "the app installs with agentv app install --local" grep -q "^Installed Profile check 1.0.0" "$RUN_DIR/install.log"

api() {
  ssh_guest "curl -s -H 'Content-Type: application/json' $*" 2>/dev/null || true
}
profiles() {
  api "http://127.0.0.1:3000/api/apps/$id/profiles"
}
# opened_as <name> <count> <seconds>: until the service has had <count>
# visits to that profile's page.
opened_as() {
  local started=$SECONDS
  until (( $(ssh_guest "grep -c 'GET /as/$1.html' $work/site/requests.log" 2>/dev/null || echo 0) >= $2 )); do
    (( SECONDS - started < $3 )) || return 1
    sleep 1
  done
}
visits() {
  ssh_guest "grep -c 'GET /as/' $work/site/requests.log" 2>/dev/null || echo 0
}

# An adult opens it: it lists the service's profiles, and leaves it on the
# picker.
guest "agentv screen app $id" >"$RUN_DIR/open-adult.json" 2>&1 || true
listed() {
  local started=$SECONDS
  until [[ $(profiles | jq -c '.names' 2>/dev/null) == '["Radomir","Kids"]' ]]; do
    (( SECONDS - started < 40 )) || return 1
    sleep 1
  done
}
check "ADR-009 the first time an adult opens it, it lists the service's profiles" listed
check "and no profile is opened for an adult" test "$(visits)" = "0"

# An adult picks the one for children, and adds a child, past the PIN.
check "an adult picks Kids for children" jq -e '.ok == true' <<<"$(api "-X PUT -d '{\"name\":\"Kids\"}' http://127.0.0.1:3000/api/apps/$id/child-profile")"
api "-X PUT -d '{\"pin\":\"$PIN\"}' http://127.0.0.1:3000/api/pin" >"$RUN_DIR/pin.json"
grant=$(api "-d '{\"pin\":\"$PIN\"}' http://127.0.0.1:3000/api/pin/check" | jq -r '.grant // empty')
child=$(api "-H 'X-AgenTV-Grant: $grant' -d '{\"name\":\"mila\",\"role\":\"child\"}' http://127.0.0.1:3000/api/viewers" | jq -r '.profile.id // empty')
check "a child's profile is added" test -n "$child"
api "-H 'X-AgenTV-Grant: $grant' -d '{\"allowed\":true}' http://127.0.0.1:3000/api/apps/$id/for-children" >"$RUN_DIR/for-children.json"
check "and the app is ticked for children" jq -e '.ok == true' "$RUN_DIR/for-children.json"

# A child starts watching with the app open: it opens the profile for
# children.
api "-d '{\"id\":\"$child\"}' http://127.0.0.1:3000/api/viewer" >"$RUN_DIR/switch-child.json"
check "ADR-009 a child starting to watch with the app open gets the profile for children" opened_as kids 1 40
capture_console "success-child-profile-switch"

# Opened by a child, it opens it again.
guest "agentv screen quit $id" >/dev/null 2>&1 || true
sleep 2
guest "agentv screen app $id" >"$RUN_DIR/open-child.json" 2>&1 || true
check "ADR-009 the app opened by a child opens the profile for children" opened_as kids 2 40
check "and never an adult's" test "$(ssh_guest "grep -c 'GET /as/radomir.html' $work/site/requests.log" 2>/dev/null || echo 0)" = "0"

# Back to an adult: opening it leaves the service's profile as it is.
guest "agentv screen quit $id" >/dev/null 2>&1 || true
api "-H 'X-AgenTV-Grant: $grant' -d '{\"id\":\"$GUEST_USER\"}' http://127.0.0.1:3000/api/viewer" >"$RUN_DIR/switch-adult.json"
sleep 2
guest "agentv screen app $id" >"$RUN_DIR/open-adult-again.json" 2>&1 || true
sleep 15
check "ADR-009 an adult opening it again leaves the service's profile as it is" test "$(visits)" = "2"

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen.log" 2>&1 || true
check "the screen daemon logs the profile for children opening" grep -q "$id: opened the profile for children" "$RUN_DIR/screen.log"
guest "agentv screen quit $id" >/dev/null 2>&1 || true
guest "agentv app remove $id" >/dev/null 2>&1 || true
stop_vm
finish
