#!/bin/bash
#
# TV setup's apps (board 09): the official apps for what the TV is for come
# from AgenTV's signed index, and the one ticked on the TV installs as root,
# through agentv-setup-apps.path, with `agentv app install`, while setup
# finishes and home takes over. Then home has it.
#
# The steps before the apps go by on the daemon's own API, as the setup
# screens move them on; the apps step is driven with the TV's keys, as from
# the remote. The box fetches the index and the app from GitHub, as a real
# box does.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# until_json <url path> <jq filter> <seconds>: until the filter on what the
# daemon answers there is true.
until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "curl -fsS --max-time 10 http://127.0.0.1:3000$1" 2>/dev/null | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 2
  done
  return 1
}

# until_file <jq filter> <file> <seconds>: until the filter on a file on the
# box is true.
until_file() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "cat $2 2>/dev/null" | jq -r "$1" 2>/dev/null) == "true" ]] && return 0
    sleep 3
  done
  return 1
}

# setup_post <path> <json>: a step moved on, as the setup screens do it.
setup_post() {
  ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '$2' http://127.0.0.1:3000$1" >>"$RUN_DIR/setup-posts.log" 2>&1
}

start_vm_from_base
wait_for_ssh 300 failure-setup-apps-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
check "setup starts on the welcome screen" until_json /api/setup '.setup.step == "welcome"' 30
check "the hand-over to root is waiting for setup's apps" test "$(ssh_guest "systemctl is-active agentv-setup-apps.path")" = "active"

setup_post /api/setup/finish '{"step": "welcome", "keyboard": true}'
setup_post /api/setup/ready '{"update": "none"}'
setup_post /api/setup/finish '{"step": "ready"}'
setup_post /api/setup/finish '{"step": "ai"}'
setup_post /api/setup/finish '{"step": "people"}'
setup_post /api/setup/goal '{"goal": "media"}'
setup_post /api/setup/finish '{"step": "goal"}'
check "setup is at its apps" until_json /api/setup '.setup.step == "apps"' 30

# The goal's apps are Jellyfin, Plex and Immich, in that order, each once
# it's in the index.
# shellcheck disable=SC2016 # $f and $id are jq's own
check "the official apps for photos come from the signed index, in the goal's order: Jellyfin first, Immich among them" \
  until_json /api/setup/apps '[.for[].id] as $f | ($f | index("agentv.jellyfin")) == 0 and ($f | index("agentv.immich")) != null and ($f == (["agentv.jellyfin", "agentv.plex", "agentv.immich"] | map(select(. as $id | $f | index($id) != null)))) and (.error == null)' 120
ssh_guest "curl -fsS http://127.0.0.1:3000/api/setup/apps" >"$RUN_DIR/setup-apps.json" 2>&1 || true
log "the goal's apps: $(jq -c '[.for[].id]' "$RUN_DIR/setup-apps.json" 2>/dev/null)"
check "Steam and the built-in Music are under more" jq -e '[.more[].id] | index("agentv.steam") != null and index("agentv.music") != null' "$RUN_DIR/setup-apps.json"
check "the apps step is on the TV (OCR)" ocr_finds success-setup-apps "pick your apps|add your own" 30
capture_console "success-setup-apps"

# Immich ticked with the remote's keys, then continue, above it. The focus
# starts on the goal's first app, so Immich is as many to the right as its
# place in the row.
rights=$(jq -r '[.for[].id] | index("agentv.immich") // 1' "$RUN_DIR/setup-apps.json" 2>/dev/null || echo 1)
keys=()
for (( i = 0; i < rights; i++ )); do keys+=(right); done
for key in "${keys[@]}" enter up enter; do
  guest "agentv input key $key" >>"$RUN_DIR/input.log" 2>&1 || true
  sleep 1
done
# Continue moves setup on: to its look once that step is there, or home.
# The steps after this one have checks of their own, so it skips them.
check "continue moves setup on from its apps" until_json /api/setup '.setup.done or (.setup.step != "apps")' 60
guest "agentv setup skip" >>"$RUN_DIR/input.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "and home takes over${took:+ (after $took s)}" test -n "$took"

log "Waiting for Immich to install"
until_file '.apps["agentv.immich"].state == "installed" or .apps["agentv.immich"].state == "failed"' /run/agentv-setup-apps/state.json 600 || true
ssh_guest "cat /run/agentv-setup-apps/state.json" >"$RUN_DIR/setup-apps-state.json" 2>&1 || true
ssh_guest "journalctl -u agentv-setup-apps.service --no-pager" >"$RUN_DIR/setup-apps-service.log" 2>&1 || true
check "the ticked app installed as root, from the index ($(jq -r '.apps["agentv.immich"] | "\(.state) \(.error // "")"' "$RUN_DIR/setup-apps-state.json" 2>/dev/null))" \
  jq -e '.apps["agentv.immich"].state == "installed"' "$RUN_DIR/setup-apps-state.json"
check "and only that one" jq -e '.apps | keys == ["agentv.immich"]' "$RUN_DIR/setup-apps-state.json"
guest "agentv app list" >"$RUN_DIR/app-list.txt" 2>&1 || true
check "agentv app list has it" grep -q '^agentv.immich ' "$RUN_DIR/app-list.txt"
check "home has it" until_json /api/home '[.apps[].id] | index("agentv.immich") != null' 30
check "the daemon's drop is gone" test -z "$(ssh_sudo "ls /var/lib/private/agentv/daemon/apps-drop 2>/dev/null")"

stop_vm
finish
