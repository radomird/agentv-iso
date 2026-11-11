#!/bin/bash
#
# Holding OK opens an app's details, on an installed box (track 16). The
# phone's remote sends a held OK, the virtual input device keeps Enter down
# for it, and the home screen opens the details of the tile with the focus
# and not the app. Layer 4 checks the hold itself in a Chromium, and the
# phone's page; this checks that a real held key, with the repeats the box
# gives it, reaches the home screen as one.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-hold-ok-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-hold-ok-no-tv"; check "the TV session came up" false; stop_vm; finish; }

# screen_says <name> <text> [<seconds>]: until OCR finds <text> on the TV,
# keeping the last screenshot as <name>.
screen_says() {
  local started=$SECONDS

  while (( SECONDS - started < ${3:-30} )); do
    ocr_screen >"$RUN_DIR/$1.txt" 2>/dev/null || true
    if grep -qiE "$2" "$RUN_DIR/$1.txt"; then
      capture_console "$1"
      return 0
    fi
    sleep 2
  done
  capture_console "$1"
  return 1
}

# What only an app's details says, in any look.
DETAILS_TEXT="for children|on home"

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

# A phone, paired the way phone-test.sh pairs one: Settings → Phones on the
# TV, then the code it shows.
guest "agentv screen settings phones" >"$RUN_DIR/settings.json" 2>&1 || true
sleep 2
guest "agentv input key enter" >"$RUN_DIR/input.log" 2>&1 || true
sleep 1
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 3
code=$(ssh_guest "curl -fsS http://127.0.0.1:3000/api/phones" 2>/dev/null | jq -r '.pairing.code // empty' 2>/dev/null || true)
address=$(ssh_guest "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -n 1" 2>/dev/null || true)
phone="http://$address:3001"
phone_key=$(ssh_guest "AGENTV_PHONE_URL=$phone agentv-phone-call pair '$code' 'test phone'" 2>/dev/null || true)
check "a phone pairs" test -n "$phone_key"

# Home, with the focus on its first tile.
guest "agentv input key home" >>"$RUN_DIR/input.log" 2>&1 || true
check "the TV shows home, with no app's details on it (OCR)" screen_says "success-hold-ok-home" "$HOME_TEXT" 30
check "home says nothing that only details says" bash -c "! grep -qiE '$DETAILS_TEXT' '$RUN_DIR/success-hold-ok-home.txt'"

# The phone's held OK, as its remote sends it once a finger has stayed on OK.
ssh_guest "AGENTV_PHONE_URL=$phone agentv-phone-call $phone_key POST /api/phone/remote '{\"hold\":\"enter\",\"ms\":700}'" >"$RUN_DIR/remote.log" 2>&1 || true
check "T16.1 a held OK from the phone's remote opens the tile's details (OCR)" screen_says "success-hold-ok-details" "$DETAILS_TEXT" 20
check "and the app didn't open: home is still in front" test "$(front '.front.role // ""')" = "home"

# Back, and a held key from a keyboard or a USB remote does the same.
guest "agentv input key back" >>"$RUN_DIR/input.log" 2>&1 || true
check "Back goes home again (OCR)" screen_says "success-hold-ok-back" "$HOME_TEXT" 15
guest "agentv input hold enter 1.2" >>"$RUN_DIR/input.log" 2>&1 || true
check "a key held for longer opens details too, once (OCR)" screen_says "success-hold-ok-long" "$DETAILS_TEXT" 20
check "and home is still in front" test "$(front '.front.role // ""')" = "home"

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen-daemon.log" 2>&1 || true

stop_vm
finish
