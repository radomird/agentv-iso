#!/bin/bash
#
# The streaming starter pack in setup (T9.2), on an installed box, in QEMU.
# With the starter switch on, setup's apps on Streaming offer every official
# app the signed index says is for streaming, each one ticked. Continue
# installs them as root, from the index, and home has a tile for each, with
# the icon its own site names.
#
# First it counts the starter pack in the box's own index, the published
# one. T9.2 wants six there, and until they're all in it, the check says how
# many there are. Then it runs the whole setup with a test index of six
# stand-in streaming apps with made-up names, signed with a key made for
# this run alone. Their sites are stand-ins the box serves itself, so no
# service's site is ever asked for anything.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

CHECK=/var/lib/agentv-check
PORT=8193
SITE="http://127.0.0.1:$PORT"
APPS=(kite harbour lantern paper reel tide)
COLOURS=("#7aa2f7" "#bb9af7" "#ff9e64" "#9ece6a" "#e0af68" "#2ac3de")

daemon_get() {
  ssh_guest "curl -fsS --max-time 30 http://127.0.0.1:3000$1" 2>/dev/null
}
setup_post() {
  ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '$2' http://127.0.0.1:3000$1" >>"$RUN_DIR/setup-posts.log" 2>&1
}
until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(daemon_get "$1" | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 2
  done
  return 1
}
until_file() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "cat $2 2>/dev/null" | jq -r "$1" 2>/dev/null) == "true" ]] && return 0
    sleep 3
  done
  return 1
}
up() {
  local started=$SECONDS
  while (( SECONDS - started < 60 )); do
    [[ -n $(health) ]] && return 0
    sleep 1
  done
  return 1
}

start_vm_from_base
wait_for_ssh 300 failure-T9.2-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-T9.2-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

# --- The switch --------------------------------------------------------------

# The starter pack's switch is on, as every box has it.
check "the starter pack's switch is on" until_json /api/features '.starter == true' 10

# --- The published index -------------------------------------------------------

# The box's own index, as setup reads it, before setup gets to its apps.
check "the box reads its own index" until_json /api/setup/apps '.error == null' 120
daemon_get /api/setup/apps >"$RUN_DIR/published.json" || true
published=$(jq '.starter | length' "$RUN_DIR/published.json" 2>/dev/null || echo 0)
log "The published index's starter pack: $(jq -c '[.starter[].name]' "$RUN_DIR/published.json" 2>/dev/null)"
if (( published >= 6 )); then
  check "T9.2 the published index's starter pack has all six streaming apps" jq -e '.starter | length == 6' "$RUN_DIR/published.json"
else
  log "It has $published of the six so far. This check counts them once they're all there."
fi

# --- Six stand-in streaming apps and their sites --------------------------------

work="$RUN_DIR/starter"
rm -rf "$work"
mkdir -p "$work/repo/apps" "$work/sites" "$work/index"
for i in "${!APPS[@]}"; do
  app=${APPS[$i]}
  mkdir -p "$work/repo/apps/$app" "$work/sites/$app"
  jq -n --arg id "agentv.check-$app" --arg name "${app^}" --arg home "$SITE/$app/" --arg origin "$SITE" '{
    schemaVersion: 1, id: $id, name: $name, version: "1.0.0", author: "agentv", license: "MIT",
    description: ($name + " on the TV, a stand-in for an image check"), kinds: ["tv-app"],
    entryPoints: {tvApp: "app.ts"},
    tv: {contract: 1, category: "streaming", runtime: "web", homeUrl: $home, capabilities: ["launch"], origins: [$origin], tiles: {s: "logo"}, childSafe: false}
  }' >"$work/repo/apps/$app/manifest.json"
  printf '// A stand-in streaming app for AgenTV'"'"'s image check: it opens its site.\nexport default { id: "agentv.check-%s", async launch(ctx) { await ctx.page?.goto("%s/%s/"); } };\n' "$app" "$SITE" "$app" >"$work/repo/apps/$app/app.ts"
  printf '<!doctype html>\n<title>%s</title>\n<link rel="icon" type="image/svg+xml" href="icon.svg">\n<h1>%s, a stand-in site</h1>\n' "${app^}" "${app^}" >"$work/sites/$app/index.html"
  printf '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="%s"/><text x="32" y="44" font-size="36" text-anchor="middle">%s</text></svg>\n' "${COLOURS[$i]}" "${app:0:1}" >"$work/sites/$app/icon.svg"
done
# The sites, served on the box by the Node that runs AgenTV's daemon.
cat >"$work/sites/serve.mjs" <<'SERVE'
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, normalize } from "node:path";
const root = new URL(".", import.meta.url).pathname;
const types = { ".html": "text/html", ".svg": "image/svg+xml" };
createServer(async (request, response) => {
  let path = normalize(decodeURIComponent(new URL(request.url, "http://x").pathname));
  if (path.endsWith("/")) path += "index.html";
  try {
    const body = await readFile(join(root, path));
    response.writeHead(200, { "Content-Type": types[path.slice(path.lastIndexOf("."))] ?? "application/octet-stream" });
    response.end(body);
  } catch {
    response.writeHead(404).end();
  }
}).listen(Number(process.argv[2]), "127.0.0.1");
SERVE

GNUPGHOME=$(mktemp -d /tmp/agentv-gpg.XXXXXX)
export GNUPGHOME
gpg --batch --quiet --passphrase '' --quick-gen-key "AgenTV image check <check@agentv.invalid>" ed25519 sign never
gpg --batch --armor --export >"$work/keyring.asc"
tar -C "$work" -czf "$work/check.tgz" repo sites keyring.asc
ssh_guest "cat >/tmp/agentv-check.tgz" <"$work/check.tgz"
ssh_sudo "install -d -m 755 $CHECK && tar -xzf /tmp/agentv-check.tgz -C $CHECK && chown -R root:root $CHECK && chmod -R a+rX $CHECK" >"$RUN_DIR/check-setup.log" 2>&1 || true
ssh_sudo "systemd-run --unit agentv-check-sites --property DynamicUser=yes /usr/bin/node $CHECK/sites/serve.mjs $PORT" >>"$RUN_DIR/check-setup.log" 2>&1 || true
check "the stand-in sites answer on the box" ssh_guest "curl -fsS $SITE/kite/ | grep -q 'a stand-in site'"

ssh_sudo "git -C $CHECK/repo init -q && git -C $CHECK/repo add -A && git -C $CHECK/repo -c user.name='AgenTV image check' -c user.email=check@agentv.invalid commit -qm 'Six stand-in streaming apps'" >>"$RUN_DIR/check-setup.log" 2>&1 || true
commit=$(ssh_sudo "git -C $CHECK/repo rev-parse HEAD" 2>/dev/null | tr -d '\r' | tail -n 1)
check "the stand-in apps' repo is on the box, at a commit ($commit)" test "${#commit}" = 40
printf '%s\n' "${APPS[@]}" | jq -R . | jq -s --arg commit "$commit" --arg repo "file://$CHECK/repo" '{schema: 1, apps: map({
  id: ("agentv.check-" + .), tier: "official", name: ((.[0:1] | ascii_upcase) + .[1:]), version: "1.0.0",
  description: "A stand-in streaming app for an image check", category: "streaming",
  repo: $repo, commit: $commit, path: ("apps/" + .)
})}' >"$work/index/index.json"
gpg --batch --quiet --detach-sign --output "$work/index/index.json.sig" "$work/index/index.json"
gpgconf --kill gpg-agent 2>/dev/null || true
rm -rf -- "${GNUPGHOME:?}"
tar -C "$work" -czf "$work/index.tgz" index
ssh_guest "cat >/tmp/agentv-check-index.tgz" <"$work/index.tgz"
ssh_sudo "tar -xzf /tmp/agentv-check-index.tgz -C $CHECK && chown -R root:root $CHECK/index && chmod -R a+rX $CHECK/index" >>"$RUN_DIR/check-setup.log" 2>&1 || true

# The daemon and root's hand-over read the test index, with its key.
for unit in agentv-daemon agentv-setup-apps; do
  ssh_sudo "install -d /etc/systemd/system/$unit.service.d && printf '[Service]\nEnvironment=AGENTV_INDEX_URL=$CHECK/index\nEnvironment=AGENTV_KEYRING=$CHECK/keyring.asc\n' >/etc/systemd/system/$unit.service.d/agentv-check.conf"
done
ssh_sudo "systemctl daemon-reload && systemctl restart agentv-daemon"
check "the daemon is back with the test index" up

# --- Setup on Streaming ----------------------------------------------------------

setup_post /api/setup/finish '{"step": "welcome", "keyboard": true}'
setup_post /api/setup/ready '{"update": "none"}'
setup_post /api/setup/finish '{"step": "ready"}'
setup_post /api/setup/finish '{"step": "country"}' || true
setup_post /api/setup/finish '{"step": "ai"}'
setup_post /api/setup/finish '{"step": "people"}'
setup_post /api/setup/goal '{"goal": "streaming"}'
setup_post /api/setup/finish '{"step": "goal"}'
check "setup is at its apps" until_json /api/setup '.setup.step == "apps"' 30
daemon_get /api/setup/apps >"$RUN_DIR/setup-apps.json" || true
ids=$(printf 'agentv.check-%s\n' "${APPS[@]}" | sort | jq -R . | jq -sc .)
# shellcheck disable=SC2016 # $ids is jq's own
check "T9.2 the starter pack is the six streaming apps in the index, and Streaming's own" \
  jq -e --argjson ids "$ids" '([.starter[].id] | sort) == $ids and .for == [] and .error == null' "$RUN_DIR/setup-apps.json"
check "T9.2 the TV says the starter pack is ticked (OCR)" ocr_finds success-T9.2-apps "starter pack is ticked" 30
capture_console "success-T9.2-apps"

# The focus starts on the pack, every app in it ticked: up to continue, and OK.
for key in up enter; do
  guest "agentv input key $key" >>"$RUN_DIR/input.log" 2>&1 || true
  sleep 1
done
check "continue moves setup on from its apps" until_json /api/setup '.setup.done or (.setup.step != "apps")' 60
guest "agentv setup skip" >>"$RUN_DIR/input.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "and home takes over${took:+ (after $took s)}" test -n "$took"

log "Waiting for the six to install"
until_file "[.apps[] | select(.state == \"installed\" or .state == \"failed\")] | length == ${#APPS[@]}" /run/agentv-setup-apps/state.json 900 || true
ssh_guest "cat /run/agentv-setup-apps/state.json" >"$RUN_DIR/setup-apps-state.json" 2>&1 || true
ssh_guest "journalctl -u agentv-setup-apps.service --no-pager" >"$RUN_DIR/setup-apps-service.log" 2>&1 || true
# shellcheck disable=SC2016 # $ids is jq's own
check "T9.2 all six installed as root, from the index ($(jq -c '[.apps[] | .state] | group_by(.) | map({(.[0]): length}) | add' "$RUN_DIR/setup-apps-state.json" 2>/dev/null))" \
  jq -e --argjson ids "$ids" '(.apps | keys | sort) == $ids and all(.apps[]; .state == "installed")' "$RUN_DIR/setup-apps-state.json"

# --- Home: six tiles, each with its site's icon ------------------------------------

check "T9.2 home has a tile for each of the six" until_json /api/home "[.apps[].id | select(startswith(\"agentv.check-\"))] | length == ${#APPS[@]}" 60
# Each tile's icon comes from its site as home lists it, in the background.
check "T9.2 each one's icon has come from its own stand-in site" \
  until_json /api/home "[.apps[] | select(.id | startswith(\"agentv.check-\")) | select(.icon != null)] | length == ${#APPS[@]}" 120
# By hash, since the test container has no cmp.
for app in "${APPS[@]}"; do
  served=$(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/apps/agentv.check-$app/icon | sha256sum" 2>/dev/null | cut -d' ' -f1)
  check "T9.2 $app's tile shows the icon its site names" test "$served" = "$(sha256sum <"$work/sites/$app/icon.svg" | cut -d' ' -f1)"
done
check "T9.2 the six tiles are on the TV (OCR)" ocr_finds success-T9.2-home "kite|harbour|lantern|paper|reel|tide" 30
capture_console "success-T9.2-home"

stop_vm
finish
