#!/bin/bash
#
# S1.3: the TV to Omarchy's desktop and back each take under 10 s (ADR-031).
# Each switch is a log-out and a log-in. First with the keys, Super+Ctrl+Home
# both ways, through QEMU's keyboard as someone at the box would; then with
# agentv desktop and agentv tv over SSH. The desktop counts as up once its
# bar is on the screen, the TV once the welcome page has been drawn again
# with the home screen in front.
#
# And Omarchy's Bluetooth pairing agent, which says yes to every pairing,
# isn't left running on the TV after a visit to the desktop. It starts with
# the desktop and nothing of Omarchy's stops it when the desktop ends, so the
# TV session stops it as it starts: on the TV only Settings pairs, and only
# game controllers. The VM has no Bluetooth, so here the unit runs a sleep in
# the agent's place; starting and stopping it is the real thing.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-S1.3-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-S1.3-no-tv"; check "the TV session came up" false; stop_vm; finish; }

# Omarchy's bt-agent.service, able to run in a VM with no Bluetooth.
guest "mkdir -p ~/.config/systemd/user/bt-agent.service.d && printf '[Unit]\nConditionPathIsDirectory=\n[Service]\nExecCondition=\nExecStart=\nExecStart=/usr/bin/sleep infinity\n' >~/.config/systemd/user/bt-agent.service.d/vm.conf && systemctl --user daemon-reload" >>"$RUN_DIR/switch.log" 2>&1 || true
check "Omarchy ships its Bluetooth pairing agent as bt-agent.service" guest "systemctl --user cat bt-agent.service | grep -q bt-agent"

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
    # The agent starts with the desktop once Omarchy's first run there has
    # enabled it. Where it has, that's checked. Where it hasn't yet, nothing
    # here can show the desktop starting it, so it's started by hand, and
    # that's only so the check back on the TV has a running agent to stop.
    if guest "systemctl --user is-enabled --quiet bt-agent.service" >>"$RUN_DIR/switch.log" 2>&1; then
      check "on the desktop, Omarchy's Bluetooth pairing agent started with it" guest "systemctl --user is-active --quiet bt-agent.service"
    else
      echo "bt-agent.service isn't enabled in this VM yet, so the desktop starting it isn't checked" >>"$RUN_DIR/switch.log"
    fi
    guest "systemctl --user start bt-agent.service" >>"$RUN_DIR/switch.log" 2>&1 || true
    check "before the switch back, the pairing agent is running, so the TV has one to stop" guest "systemctl --user is-active --quiet bt-agent.service"
  else
    took=$(wait_tv 60 "$seen") || took=""
    capture_console "success-S1.3-$how-tv"
    # What the box did while it switched, when it was slow.
    if (( ${took:-999} >= 10 )); then
      guest "journalctl --user --since '-3min' --no-pager -o short-precise" >"$RUN_DIR/slow-$how-tv-user.log" 2>&1 || true
      ssh_sudo "journalctl --since '-3min' --no-pager -o short-precise" >"$RUN_DIR/slow-$how-tv-system.log" 2>&1 || true
    fi
    check "S1.3 Omarchy's desktop back to the TV with the $how takes under 10 s (took ${took:-over 60} s)" \
      test "${took:-999}" -lt 10
    check "back on the TV, nothing of Omarchy's desktop is left" ssh_guest "! pgrep -f '$OMARCHY_SHELL' >/dev/null"
    check "back on the TV, Omarchy's Bluetooth pairing agent isn't running" guest "! systemctl --user is-active --quiet bt-agent.service"
  fi
}

switch keys desktop
switch keys tv
switch command desktop
switch command tv

# After a power on the TV comes back, even if the desktop was on, and even
# with Omarchy's own autologin to its desktop in place, which its installer
# keeps for good on an encrypted disk.
guest "agentv desktop" >>"$RUN_DIR/switch.log" 2>&1 || true
wait_desktop 60 >/dev/null || true
ssh_sudo "printf '[Autologin]\\nUser=%s\\nSession=omarchy.desktop\\n' '$GUEST_USER' >/etc/sddm.conf.d/autologin.conf"
log "Restarting the box from Omarchy's desktop"
ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
sleep 15
wait_for_ssh 300 failure-S1.3-reboot-ssh-timeout || exit 1
check "after a restart from Omarchy's desktop, the box comes back to the TV, with Omarchy's autologin beside AgenTV's" \
  wait_tv 240

cat "$RUN_DIR/switch.log" 2>/dev/null || true
stop_vm
finish
