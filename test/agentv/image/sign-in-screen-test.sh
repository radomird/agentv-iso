#!/bin/bash
#
# AgenTV's sign-in screen (ADR-032, board 15) on an installed box: a stand-in
# app with signIn, for a sign-in page served on the box itself, says Sign in
# until it's signed in. agentv screen sign-in opens it the way its tile does:
# the service's page maximized above AgenTV's bar in the overlay, which keeps
# the bottom of the screen and never the keyboard. The app takes its page to
# the site's form, the virtual keyboard fills it in as the phone will, and
# once the site's cookie says so, the app says it's signed in: the bar goes,
# the page is full screen again, and the tile stops saying Sign in.

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
<script>document.getElementById("login").addEventListener("submit", (e) => { e.preventDefault(); document.cookie = "signed=in; path=/"; location.href = "/"; });</script>
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

signin_bar() {
  guest_hyprctl "-j layers" 2>/dev/null | jq -e '[.. | objects | select(.namespace? == "agentv-signin")] | length > 0' >/dev/null
}

no_signin_bar() {
  ! signin_bar
}

page_fullscreen() {
  guest_hyprctl "-j clients" 2>/dev/null | jq -e '.[] | select(.workspace.name == "1" and .fullscreen == 2)' >/dev/null
}

signs_in() {
  ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/home" | jq -r --arg id "$id" '.apps[] | select(.id == $id) | .signIn // "done"'
}
check "the app's tile says Sign in before it's signed in" test "$(signs_in)" = "needed"

guest "agentv screen sign-in $id" >"$RUN_DIR/sign-in.json" 2>&1 || true
cat "$RUN_DIR/sign-in.json"
check "agentv screen sign-in opens the sign-in screen" jq -e '.ok == true' "$RUN_DIR/sign-in.json"

# Up to 30 s for the page, the bar, and the form.
up=0
for _ in $(seq 1 60); do
  layers=$(guest_hyprctl "-j layers" 2>/dev/null || true)
  clients=$(guest_hyprctl "-j clients" 2>/dev/null || true)
  if jq -e '[.. | objects | select(.namespace? == "agentv-signin")] | length > 0' <<<"$layers" >/dev/null 2>&1 &&
    jq -e '.[] | select(.workspace.name == "1" and .fullscreen == 1)' <<<"$clients" >/dev/null 2>&1 &&
    ssh_guest "grep -q 'GET /login.html' /tmp/agentv-sign-in-check/requests.log"; then
    up=1
    break
  fi
  sleep 0.5
done
echo "$layers" >"$RUN_DIR/layers.json"
echo "$clients" >"$RUN_DIR/clients.json"
check "the sign-in bar is in the overlay" jq -e '[.. | objects | select(.namespace? == "agentv-signin")] | length > 0' "$RUN_DIR/layers.json"
check "the service's page is maximized above it, not full screen" jq -e '.[] | select(.workspace.name == "1" and .fullscreen == 1)' "$RUN_DIR/clients.json"
height=$(guest_hyprctl "-j monitors" 2>/dev/null | jq '.[0].height / .[0].scale | floor' 2>/dev/null || echo 0)
# shellcheck disable=SC2016 # $height is jq's own
check "and the bar keeps the bottom of the screen: the page ends above it" \
  jq -e --argjson height "${height:-0}" '$height > 0 and ([.[] | select(.workspace.name == "1")][0] | .at[1] + .size[1] <= $height - 200)' "$RUN_DIR/clients.json"
check "the app took its page to the site's sign-in form" test "$up" = 1
sleep 2
capture_console "success-sign-in-screen"
# The bar's text, then its button's: beside the bar's light text on dark,
# tesseract takes the light blue "i'm signed in" button for a picture. So
# a second pass floods the bar's dark background white from its bottom
# corner first, and the button is the only dark text on light that's left.
: >"$RUN_DIR/bar.txt"
if magick "$RUN_DIR/success-sign-in-screen.png" -gravity south -crop 100%x22%+0+0 +repage "$RUN_DIR/.bar.png" 2>/dev/null; then
  magick "$RUN_DIR/.bar.png" -colorspace gray -negate -resize 200% png:- 2>/dev/null |
    tesseract - - --psm 6 >>"$RUN_DIR/bar.txt" 2>/dev/null || true
  magick "$RUN_DIR/.bar.png" -flip -fuzz 15% -fill white -draw "color 0,0 floodfill" -flip -colorspace gray -resize 200% png:- 2>/dev/null |
    tesseract - - --psm 6 >>"$RUN_DIR/bar.txt" 2>/dev/null || true
  # And the bar's right side on its own, where the button is, both ways round.
  for way in "" "-negate"; do
    # shellcheck disable=SC2086 # $way is one option or none
    magick "$RUN_DIR/.bar.png" -gravity east -crop 35%x100%+0+0 +repage -colorspace gray $way -resize 300% png:- 2>/dev/null |
      tesseract - - --psm 11 >>"$RUN_DIR/bar.txt" 2>/dev/null || true
  done
fi
cat "$RUN_DIR/bar.txt"
# When the button isn't read, what the bar looked like: its size, its
# commonest colours, and the crop itself, small, to look at from the log.
if ! grep -aqi 'signed in' "$RUN_DIR/bar.txt"; then
  magick "$RUN_DIR/.bar.png" -format "the bar's crop: %wx%h\n" info: 2>/dev/null || true
  magick "$RUN_DIR/.bar.png" -colors 12 -format %c histogram:info:- 2>/dev/null | sort -rn | head -n 12 || true
  echo "--- the bar, as a PNG in base64 ---"
  magick "$RUN_DIR/.bar.png" -resize 50% -colors 64 png:- 2>/dev/null | base64 -w 0 || true
  echo
  echo "--- end of the bar ---"
fi
# All of where to type: a long name running into it garbles its start.
check "the bar says where to type, and i'm signed in (OCR)" bash -c "grep -aqi 'type on your phone or keyboard' '$RUN_DIR/bar.txt' && grep -aqi 'signed in' '$RUN_DIR/bar.txt'"

# Typed the way the phone will, the password from stdin.
printf 'viewer@example.org\tcheck-%s' "$RANDOM$RANDOM" | ssh_guest "bash -lc 'agentv input text -'" >"$RUN_DIR/input.log" 2>&1 || true
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true

done_at=""
for second in $(seq 1 20); do
  if [[ $(signs_in) == "done" ]]; then
    done_at=$second
    break
  fi
  sleep 1
done
check "once the form is sent, the app says it's signed in, and the tile stops saying Sign in" test -n "$done_at"
sleep 2
check "the sign-in bar is gone" no_signin_bar
check "and the page is full screen again" page_fullscreen

guest "journalctl --user -b --no-pager -u agentv-screen -u agentv-input" >"$RUN_DIR/tv-session.log" 2>&1 || true
check "the screen daemon says the sign-in is over because it signed in" grep -q "sign-in to $id over: signed in" "$RUN_DIR/tv-session.log"
check "nothing the keyboard typed is in the TV session's log" bash -c "! grep -q 'check-[0-9]' '$RUN_DIR/tv-session.log'"

guest "agentv screen quit $id" >/dev/null 2>&1 || true
ssh_sudo "rm -rf /var/lib/agentv/apps/$id && jq --arg id $id 'del(.[\$id])' /var/lib/agentv/apps/installed.json >/tmp/installed.json && install -m 644 /tmp/installed.json /var/lib/agentv/apps/installed.json" || true
stop_vm
finish
