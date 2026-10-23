#!/bin/bash
#
# S1.3: the TV to Omarchy's desktop and back each take under 10 s (ADR-031).
# Each switch is a log-out and a log-in. First with the keys, Super+Ctrl+Home
# both ways, through QEMU's keyboard as someone at the box would; then with
# agentv desktop and agentv tv over SSH. The desktop counts as up once its
# bar is on the screen, the TV once the welcome page has been drawn again
# with the home screen in front.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-S1.3-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-S1.3-no-tv"; check "the TV session came up" false; stop_vm; finish; }

count() {
  jq -r '.welcome_shown_count // 0' <<<"$(health)" 2>/dev/null || echo 0
}

# switch <how> <to>: one switch, timed. <how> is keys or command.
switch() {
  local how="$1" to="$2" seen took

  seen=$(count)
  if [[ $how == keys ]]; then
    press meta_l-ctrl-home
  elif [[ $to == desktop ]]; then
    guest "agentv desktop" >>"$RUN_DIR/switch.log" 2>&1 || true
  else
    guest "agentv tv" >>"$RUN_DIR/switch.log" 2>&1 || true
  fi

  if [[ $to == desktop ]]; then
    took=$(wait_desktop 60) || took=""
    capture_console "success-S1.3-$how-desktop"
    check "S1.3 the TV to Omarchy's desktop with the $how takes under 10 s (took ${took:-over 60} s)" \
      test "${took:-999}" -lt 10
    check "it's Omarchy's own desktop: its shell is running" ssh_guest "pgrep -f '$OMARCHY_SHELL' >/dev/null"
  else
    took=$(wait_tv 60 "$seen") || took=""
    capture_console "success-S1.3-$how-tv"
    check "S1.3 Omarchy's desktop back to the TV with the $how takes under 10 s (took ${took:-over 60} s)" \
      test "${took:-999}" -lt 10
    check "back on the TV, nothing of Omarchy's desktop is left" ssh_guest "! pgrep -f '$OMARCHY_SHELL' >/dev/null"
  fi
}

switch keys desktop
switch keys tv
switch command desktop
switch command tv

# After a power on the TV comes back, even if the desktop was on.
guest "agentv desktop" >>"$RUN_DIR/switch.log" 2>&1 || true
wait_desktop 60 >/dev/null || true
log "Restarting the box from Omarchy's desktop"
ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
sleep 15
wait_for_ssh 300 failure-S1.3-reboot-ssh-timeout || exit 1
check "after a restart from Omarchy's desktop, the box comes back to the TV" wait_tv 240

cat "$RUN_DIR/switch.log" 2>/dev/null || true
stop_vm
finish
