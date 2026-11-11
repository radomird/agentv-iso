#!/bin/bash
# TRIAL: what wakes the VM from suspend to idle.
( sleep 840; echo "TRIAL: out of time" >&2; pkill -TERM -P $$ ssh; kill -TERM $$ ) &
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"
base_image_ready || exit 1
start_vm_from_base
wait_for_ssh 300 failure-x3-ssh || exit 1
wait_tv 240 >/dev/null || true
quick() { timeout "$1" ssh -i "$SSH_KEY" -p "$SSH_PORT" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR "$GUEST_USER@127.0.0.1" "${@:2}"; }
qsudo() { quick "$1" "echo $GUEST_PASSWORD | sudo -S -p '' bash -c $(printf %q "$2")"; }
back() { local started=$SECONDS; while (( SECONDS - started < $1 )); do quick 8 true 2>/dev/null && return 0; sleep 2; done; return 1; }
qsudo 30 "echo s2idle >/sys/power/mem_sleep; cat /sys/power/mem_sleep; grep . /sys/bus/serio/devices/*/power/wakeup /sys/bus/acpi/devices/*/power/wakeup /sys/bus/platform/devices/*/power/wakeup 2>/dev/null; cat /proc/acpi/wakeup; grep -i HandlePower -r /etc/systemd/logind.conf /etc/systemd/logind.conf.d 2>/dev/null" >"$RUN_DIR/wake-sources.txt" 2>&1 || true
try() {
  qsudo 15 "systemctl suspend" || true
  sleep 25
  if quick 8 true 2>/dev/null; then log "$1: the box still answers 25 s after suspend"; fi
  "${@:2}"
  if back 60; then log "$1 woke it"; check "$1 wakes it" true; return 0; fi
  log "$1 did not wake it"
  check "$1 wakes it" false
  return 1
}
rtc() { :; }
try "a key" press shift ||
  try_next=1
if [[ -n ${try_next:-} ]]; then
  # Whatever wakes it now, so the next one gets a turn.
  press ret; qmp '"system_powerdown"' >/dev/null; back 60 || { qmp '"system_reset"' >/dev/null; wait_for_ssh 300 failure-x3-reset || exit 1; qsudo 30 "echo s2idle >/sys/power/mem_sleep"; }
fi
try "the power button" qmp '"system_powerdown"' || true
back 90 || true
qsudo 60 "journalctl -b --no-pager -k | grep -i 'PM:\|s2idle\|wake' | tail -n 60; journalctl -b --no-pager -u systemd-logind | tail -n 30" >"$RUN_DIR/after.txt" 2>&1 || true
stop_vm
finish
