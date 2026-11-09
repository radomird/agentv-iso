#!/bin/bash
#
# T7.5: picking one of the theme's own backgrounds on the TV changes what
# Omarchy shows. Settings → Themes and backgrounds and setup's theme and
# background ask the screen daemon for it. Here `agentv screen background
# <id>` asks the same thing over the daemon's socket, as the owner. Omarchy's
# own omarchy-theme-bg-set moves its background link to that picture, and the
# TV hears it. Tokyo Night has more than one background.
#
# A box whose screen daemon can't pick one yet stands this check down.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# until_json <url path> <jq filter> <seconds>: until the filter on what the
# daemon answers there is true.
until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000$1" 2>/dev/null | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 0.5
  done
  return 1
}

backgrounds() {
  ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/backgrounds" 2>/dev/null | jq -r "$1" 2>/dev/null || true
}

# The picture Omarchy's background link points at, by the id the TV gives it:
# the first 16 hex digits of its SHA-256.
shown() {
  guest "sha256sum \"\$(readlink -f ~/.local/state/omarchy/current/background)\" | cut -c1-16" 2>/dev/null || true
}

start_vm_from_base
wait_for_ssh 300 failure-T7.5-ssh-timeout || exit 1
wait_tv 300 >/dev/null || true
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "setup skipped, home is in front${took:+ (after $took s)}" test -n "$took"

if ! guest "agentv screen --help" 2>/dev/null | grep -q "background <id>"; then
  log "This agentv's screen daemon can't pick one of the theme's backgrounds yet ($(guest "agentv version" 2>/dev/null | head -n 1)); T7.5 waits for it"
  stop_vm
  finish
  exit 0
fi

guest "OMARCHY_PATH=/usr/share/omarchy PATH=/usr/share/omarchy/bin:\$PATH omarchy-theme-set tokyo-night" >"$RUN_DIR/theme-set.log" 2>&1 || true
check "the TV has Tokyo Night's backgrounds, more than one" until_json /api/backgrounds '.theme.name == "tokyo-night" and (.theme.items | length) > 1' 60
current=$(backgrounds '.theme.current')
check "and the one Omarchy shows is the one its link points at ($current)" test "$current" = "$(shown)"

# Another of its pictures. $c is jq's own.
# shellcheck disable=SC2016
other=$(backgrounds '(.theme.current) as $c | [.theme.items[] | select(.id != $c and (.media // "image") == "image")][0].id // ""')
check "and there's another picture to pick (${other:-none})" grep -Eq '^[0-9a-f]{16}$' <<<"$other"

answer=$(guest "agentv screen background $other" 2>&1 || true)
log "agentv screen background $other: $answer"
check "T7.5 the screen daemon says Omarchy shows it" jq -e '.ok == true' <<<"$answer"
check "T7.5 Omarchy's background link points at that picture now" test "$(shown)" = "$other"
check "T7.5 and the TV hears it" until_json /api/backgrounds ".theme.current == \"$other\"" 20

# One that isn't the theme's changes nothing.
answer=$(guest "agentv screen background 0000000000000000" 2>&1 || true)
log "agentv screen background 0000000000000000: $answer"
check "T7.5 a picture that isn't the theme's is refused" jq -e '.ok == false' <<<"$answer"
check "and Omarchy still shows the one picked" test "$(shown)" = "$other"
capture_console "success-T7.5-picked"

guest "journalctl --user -b --no-pager -u agentv-screen | grep -i 'background' | tail -n 20" >"$RUN_DIR/screen-background.log" 2>&1 || true
stop_vm
finish
