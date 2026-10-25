#!/bin/bash
#
# The phone companion's sign-in fields and arrange home on an installed box
# (ADR-032, S4.4, S4.7, S4.9). A paired phone moves a tile on home, and the
# daemon keeps it. Then a stand-in app with signIn opens AgenTV's sign-in
# screen: the daemon hears it from the screen daemon and offers the phone its
# fields, and the email and password the phone sends are typed into the
# service's own form on the TV, through the virtual input device. The form
# gets the email as typed, the app says it's signed in, and no log on the
# box has the password. A real phone's password
# manager filling the fields is the NUC's check.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-sign-in-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-sign-in-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

id=local.sign-in-check
site=http://127.0.0.1:8767

# The service: a home page, and its own sign-in form, which sets its cookie.
ssh_guest "mkdir -p /tmp/agentv-sign-in-check && cat >/tmp/agentv-sign-in-check/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Check TV</title>
<body style="background:#fff;color:#000;font:28px sans-serif;margin:60px"><h1>Check TV</h1><p>Welcome.</p></body>
HTML
ssh_guest "cat >/tmp/agentv-sign-in-check/login.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Sign in to Check TV</title>
<body style="background:#fff;color:#000;font:28px sans-serif;margin:60px">
<h1>Sign in to Check TV</h1>
<form id="login"><input name="email" autocomplete="username" autofocus><input name="password" type="password" autocomplete="current-password"><button>Sign in</button></form>
<script>document.getElementById("login").addEventListener("submit", (e) => { e.preventDefault(); document.cookie = "signed=in; path=/"; location.href = "/?email=" + encodeURIComponent(e.target.email.value); });</script>
</body>
HTML
ssh_guest "cd /tmp/agentv-sign-in-check && (nohup python3 -m http.server 8767 --bind 127.0.0.1 >requests.log 2>&1 &)"

# The app: it asks the site's cookie whether it's signed in, and takes its
# page to the form.
ssh_guest "mkdir -p /tmp/agentv-sign-in-check/app && cat >/tmp/agentv-sign-in-check/app/manifest.json" <<JSON
{
  "schemaVersion": 1, "id": "$id", "name": "Sign-in check", "version": "1.0.0", "author": "agentv", "license": "MIT",
  "description": "A stand-in for a streaming service with a sign-in", "kinds": ["tv-app"], "entryPoints": { "tvApp": "app.ts" },
  "tv": { "contract": 1, "category": "streaming", "runtime": "web", "homeUrl": "$site/", "origins": ["$site"],
    "capabilities": ["launch", "signIn"], "setup": [{ "type": "signIn" }], "kidsSafe": true }
}
JSON
ssh_guest "cat >/tmp/agentv-sign-in-check/app/app.ts" <<'APP'
export default {
  id: "local.sign-in-check",
  async launch() {},
  signIn: {
    async isSignedIn(ctx) {
      return ctx.page.evaluate(() => document.cookie.split("; ").includes("signed=in"));
    },
    async open(ctx) {
      await ctx.page.goto("http://127.0.0.1:8767/login.html");
    },
  },
};
APP
ssh_sudo "install -d -m 755 /var/lib/agentv/apps/$id && install -m 644 /tmp/agentv-sign-in-check/app/manifest.json /tmp/agentv-sign-in-check/app/app.ts /var/lib/agentv/apps/$id/ &&
  record=/var/lib/agentv/apps/installed.json && { [ -f \$record ] || echo '{}' >\$record; } &&
  jq --arg id $id '. + {(\$id): {id: \$id, name: \"Sign-in check\", version: \"1.0.0\", tier: \"local\", installedAt: (now | todate)}}' \$record >\$record.new &&
  chmod 644 \$record.new && mv \$record.new \$record"

signs_in() {
  ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/home" | jq -r --arg id "$id" '.apps[] | select(.id == $id) | .signIn // "done"'
}
check "the app's tile says Sign in before it's signed in" test "$(signs_in)" = "needed"

# A phone, paired on the box's own address.
address=$(ssh_guest "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -n 1" 2>/dev/null || true)
phone="http://$address:3001"
code=$(ssh_guest "curl -fsS -X POST http://127.0.0.1:3000/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
token=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\":\"$code\",\"name\":\"test phone\"}' $phone/api/phone/pair" 2>/dev/null | jq -r '.token // empty')
check "a phone pairs" test -n "$token"
on_phone() {
  ssh_guest "curl -fsS -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' $*"
}

# S4.7: a tile moved on the phone is where the daemon keeps it.
on_phone "-X PUT -d '{\"layout\":[{\"id\":\"apps\",\"x\":3,\"y\":2,\"size\":\"s\"}]}' $phone/api/phone/layout" >"$RUN_DIR/layout.json" 2>&1 || true
moved() {
  [[ $(ssh_guest "curl -fsS http://127.0.0.1:3000/api/home" 2>/dev/null | jq -c '[.layout[] | select(.id == "apps") | [.x, .y]]') == "[[3,2]]" ]]
}
check "S4.7 a tile moved on the phone is moved on home" moved

no_fields() {
  [[ $(on_phone "$phone/api/phone/state" 2>/dev/null | jq -c '.signIn') == "null" ]]
}
check "with nothing signing in, the phone offers no fields" no_fields

guest "agentv screen sign-in $id" >"$RUN_DIR/sign-in.json" 2>&1 || true
check "agentv screen sign-in opens the sign-in screen" jq -e '.ok == true' "$RUN_DIR/sign-in.json"
up=0
for _ in $(seq 1 60); do
  if ssh_guest "grep -q 'GET /login.html' /tmp/agentv-sign-in-check/requests.log" 2>/dev/null; then
    up=1
    break
  fi
  sleep 0.5
done
check "the app took its page to the site's sign-in form" test "$up" = 1
sleep 3
fields() {
  [[ $(on_phone "$phone/api/phone/state" 2>/dev/null | jq -r '.signIn.name // empty') == "Sign-in check" ]]
}
check "S4.9 the daemon hears the sign-in screen is up, and offers the phone its fields" fields

PASSWORD="hunter2-image-check"
on_phone "-d '{\"username\":\"ana@example.org\",\"password\":\"$PASSWORD\"}' $phone/api/phone/sign-in" >"$RUN_DIR/sent.json" 2>&1 || true
check "the phone's name and password go to the TV" jq -e '.ok == true' "$RUN_DIR/sent.json"
done_at=""
for second in $(seq 1 30); do
  if [[ $(signs_in) == "done" ]]; then
    done_at=$second
    break
  fi
  sleep 1
done
capture_console "success-phone-sign-in"
check "S4.9 they fill the service's form on the TV, and the app says it's signed in" test -n "$done_at"
# The form sends its email field on, so the stand-in's log says what was typed.
emailed() {
  ssh_guest "grep -q 'GET /?email=ana%40example.org ' /tmp/agentv-sign-in-check/requests.log"
}
check "S4.4 the email typed on the phone is the one the service's form got" emailed
sleep 2
check "the sign-in screen is over, and the phone's fields go" no_fields

guest "journalctl --user -b --no-pager" >"$RUN_DIR/user-journal.log" 2>&1 || true
ssh_sudo "journalctl -b --no-pager" >"$RUN_DIR/journal.log" 2>&1 || true
not_logged() {
  ! grep -q "$PASSWORD" "$RUN_DIR/user-journal.log" "$RUN_DIR/journal.log"
}
check "S4.9 no log on the box has the password" not_logged

stop_vm
finish
