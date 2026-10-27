#!/bin/bash
#
# S0.1: the installed box boots to the TV setup welcome screen on its own.
# No boot password and no login (agentv-firstboot set up autologin), the
# kiosk opens the welcome page, and the page has told the daemon it's on
# screen. The screenshot goes with the run for a person to look at.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

log "Booting the installed system with no key pressed"
start_vm_from_base
wait_for_ssh 300 failure-S0.1-ssh-timeout || exit 1

check "agentv-firstboot ran" ssh_guest "test -f /var/lib/agentv/firstboot.done"
check "the daemon is running" ssh_guest "systemctl is-active --quiet agentv-daemon"
check "the owner logs in on their own" ssh_guest "grep -qx 'User=$GUEST_USER' /etc/sddm.conf.d/zz-agentv-autologin.conf"

# The page reports itself once the kiosk has drawn it.
health=""
for _ in $(seq 1 60); do
  health=$(ssh_guest "curl -fsS http://127.0.0.1:3000/health" 2>/dev/null || true)
  [[ $(jq -r '.welcome_shown // false' <<<"$health" 2>/dev/null) == "true" ]] && break
  sleep 5
done
printf '%s\n' "$health" >"$RUN_DIR/health.json"
check "S0.1 the welcome screen is on the TV (daemon /health)" \
  test "$(jq -r '.screen + " " + (.welcome_shown | tostring)' <<<"$health" 2>/dev/null)" = "welcome true"

# The kiosk fills the screen with the page; give it a beat to settle.
sleep 5
capture_console "success-S0.1-welcome"
# TV setup's welcome screen has the code to pair the phone beside its words,
# so OCR reads it as scattered text too (ocr_finds).
check "S0.1 the screen shows the welcome page (OCR)" ocr_finds success-S0.1-welcome-ocr "tv setup" 15

stop_vm
finish
