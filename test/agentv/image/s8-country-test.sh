#!/bin/bash
#
# Where the TV is on an installed box (ADR-055). Setup's country step comes
# after getting ready and starts on the country of the box's time zone, so
# one press of OK confirms it. Another country, as Settings → country picks
# one, moves the time zone with it: the daemon hands the zone to root,
# agentv-zone.path starts agentv-zone-set, and timedatectl sets it. Clock,
# Weather and New this week's region follow. A drop with a zone zone.tab
# doesn't list changes nothing.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-S8-country-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-S8-country-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

setup_post() {
  ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '$2' http://127.0.0.1:3000$1" >>"$RUN_DIR/setup-posts.log" 2>&1
}
until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000$1" 2>/dev/null | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 1
}
zone_now() {
  ssh_guest "timedatectl show -p Timezone --value" 2>/dev/null
}
until_zone() {
  local started=$SECONDS
  while (( SECONDS - started < 30 )); do
    [[ $(zone_now) == "$1" ]] && return 0
    sleep 1
  done
  return 1
}

check "the time zone's hand-over to root runs" ssh_guest "systemctl is-active --quiet agentv-zone.path"

# The installer set Oslo's time zone, say.
ssh_sudo "timedatectl set-timezone Europe/Oslo" >"$RUN_DIR/timezone.log" 2>&1 || true
check "the box is in Oslo's time zone" until_zone Europe/Oslo

# --- Setup: past the welcome screen and getting ready, to where the TV is -------

setup_post /api/setup/finish '{"step": "welcome", "keyboard": true}'
setup_post /api/setup/ready '{"update": "none"}'
setup_post /api/setup/finish '{"step": "ready"}'
check "ADR-055 setup's step after getting ready is the country" until_json /api/setup '.setup.step == "country"' 30
check "ADR-055 it asks where the TV is, starting on the time zone's country (OCR)" ocr_finds success-S8-country "norway" 30
capture_console "success-S8-country"
check "the daemon has Norway, from the time zone, not picked yet" until_json /api/country '.code == "NO" and .picked == false and .zone == "Europe/Oslo"' 10

# One press of OK.
press ret
check "ADR-055 one press of OK confirms it, and setup moves on to the AI step" until_json /api/setup '.setup.step == "ai"' 30
check "Norway is kept, picked" until_json /api/country '.code == "NO" and .picked == true' 10
check "and the time zone stays Oslo's" test "$(zone_now)" = "Europe/Oslo"

# --- Another country, as Settings → country picks one ------------------------

ssh_guest "curl -sS --max-time 30 -X PUT -H 'Content-Type: application/json' -d '{\"code\":\"US\"}' http://127.0.0.1:3000/api/country" >"$RUN_DIR/us.json" 2>&1 || true
check "ADR-055 another country is kept" jq -e '.code == "US" and .picked == true' "$RUN_DIR/us.json"
check "ADR-055 and root moves the time zone to the one most of its people live in (Q165)" until_zone America/New_York
check "Clock and Weather follow it" until_json /api/weather '.zone == "America/New_York"' 30
check "New this week's region follows it" until_json /api/whats-new/settings '.region == "US"' 10

# --- A zone zone.tab doesn't list, dropped by hand, changes nothing ---------------

ssh_sudo "printf '{\"zone\":\"Europe/Atlantis\"}' >/var/lib/private/agentv/daemon/zone-drop/zone.json" >>"$RUN_DIR/timezone.log" 2>&1 || true
sleep 5
check "a zone zone.tab doesn't list changes nothing" test "$(zone_now)" = "America/New_York"
check "and its drop is gone" ssh_sudo "test ! -e /var/lib/private/agentv/daemon/zone-drop/zone.json"

ssh_sudo "journalctl -b --no-pager -u agentv-zone -u agentv-daemon" >"$RUN_DIR/journal.log" 2>&1 || true
check "the journal says root set New York's zone, and turned the other away" \
  sh -c "grep -q \"agentv-zone-set: the box's time zone is America/New_York\" '$RUN_DIR/journal.log' && grep -q \"the drop's zone isn't one zone.tab lists\" '$RUN_DIR/journal.log'"

stop_vm
finish
