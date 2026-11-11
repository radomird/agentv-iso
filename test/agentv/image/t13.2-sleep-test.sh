#!/bin/bash
#
# Sleep as a setting on an installed box (ADR-072, T13.2). With the TV
# reported off (agentv screen tv off stands in for its power, which a VM
# can't switch) and the hour shortened to 2 minutes (agentv screen
# sleep-after), long enough after a wake to look before it sleeps again:
#   - with Settings → Power's sleep off, the box never suspends, and once the
#     apps have closed, home waits on its ambient screen with the output off;
#   - with it on, it doesn't suspend while something holds an inhibitor that
#     blocks sleep, and says who;
#   - once that's let go, it suspends, and the power button (QEMU's wake, or
#     its ACPI button) wakes it to the ambient screen;
#   - after the box has been awake for the hour again, it sleeps again, and a
#     key on the keyboard wakes it.
# The kernel's own log says each suspend went in and came out.
#
# The VM's GPU sits behind a PCIe port and keeps its state across the sleep,
# as a real GPU does. Upstream's VM has virtio's GPU on the root bus, where
# the kernel resets it on every wake and its driver never sets its queues up
# again. QEMU then takes no more commands from it. A few frames later the
# queue is full, the kernel's next change to the display waits for good, and
# Hyprland waits with it: no hyprctl answers, and the next sleep never ends.
# How soon depended on how much was drawn, so this check passed or failed by
# luck (2026-11-11).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# Upstream's start_vm, with its GPU moved behind a port. It stops here if
# upstream's line has changed, so the swap is never silently lost.
GPU_KEEPS_STATE="-device pcie-root-port,id=gpuport,chassis=9 -device virtio-vga,bus=gpuport,x-pcie-pm-no-soft-reset=on"
vm=$(declare -f start_vm)
if [[ $vm != *"-device virtio-vga"* ]]; then
  echo "upstream's start_vm has no '-device virtio-vga' to move behind a port" >&2
  exit 1
fi
vm=${vm/start_vm/start_vm_gpu_keeps_state}
eval "${vm/-device virtio-vga/$GPU_KEEPS_STATE}"

# As upstream's start_vm_from_base starts it.
qemu-img create -f qcow2 -b "$BASE_DISK" -F qcow2 "$RUN_DIR/run.qcow2" >/dev/null
if [[ $FIRMWARE == "uefi" ]]; then
  cp "$BASE_OVMF" "$RUN_DIR/OVMF_VARS.4m.fd"
  # shellcheck disable=SC2034 # start_vm in base-test.sh reads it
  ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
fi
start_vm_gpu_keeps_state "$RUN_DIR/run.qcow2" "$RUN_DIR/serial.log"
wait_for_ssh 300 failure-sleep-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-sleep-no-tv"; check "the TV session came up" false; stop_vm; finish; }

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

# Sleep is daemon/sleep.ts. The Nightly's edge leg runs this on edge's last
# build, which may be from before it, so on a box without it this waits.
if ! ssh_guest "test -f /usr/share/agentv/daemon/sleep.ts"; then
  log "This agentv can't sleep yet ($(guest "agentv version" 2>/dev/null | head -n 1)); T13.2 waits for it"
  stop_vm
  finish
  exit 0
fi

ssh_guest "cat /sys/power/state /sys/power/mem_sleep" >"$RUN_DIR/power-states.txt" 2>&1 || true
log "The kernel offers: $(tr '\n' ' ' <"$RUN_DIR/power-states.txt")"
check "the kernel offers suspend to RAM" grep -qw mem "$RUN_DIR/power-states.txt"
ssh_guest "lspci -vv -d 1af4:1050" >"$RUN_DIR/gpu.txt" 2>&1 || true
check "the VM's GPU keeps its state across a sleep" grep -q "NoSoftRst+" "$RUN_DIR/gpu.txt"

# SSH that gives up after <seconds>: a suspended box takes the connection
# and never answers, which ConnectTimeout alone doesn't cover. timeout can't
# run a shell function, so this is ssh itself, as ssh_guest runs it.
ssh_quick() {
  local seconds=$1
  shift
  timeout "$seconds" ssh -i "$SSH_KEY" -p "$SSH_PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR \
    "$GUEST_USER@127.0.0.1" "$@"
}

# Suspends the kernel went into this boot, and came out of, or "?" when the
# box doesn't answer, which is never taken for none.
pm_count() {
  local out
  if out=$(ssh_quick 20 "echo $GUEST_PASSWORD | sudo -S -p '' journalctl -k -b --no-pager | grep -c 'PM: suspend $1' || true" 2>/dev/null); then
    echo "$out"
  else
    echo "?"
  fi
}
entries() { pm_count entry; }
exits() { pm_count exit; }
screen_log() { ssh_quick 20 "journalctl --user -b --no-pager -u agentv-screen" 2>/dev/null || true; }
settings() {
  guest "curl -fsS --max-time 5 -X POST -H 'content-type: application/json' -d '$1' http://127.0.0.1:3000/api/settings" >>"$RUN_DIR/settings.log" 2>&1
}
# What Hyprland is doing, for a run where it stops answering: its instances,
# where each of its threads waits in the kernel, the kernel's own threads in
# the display's code, and the end of the kernel's log.
read -r -d '' HYPRLAND_LOOK <<'LOOK' || true
ls -la --time-style=full-iso /run/user/*/hypr/ 2>&1
for pid in $(pgrep -x Hyprland); do
  ps -L -o pid,tid,lstart,stat,wchan:40,comm -p "$pid"
  for task in /proc/$pid/task/*; do
    echo "-- $(cat "$task/comm") ${task##*/}"
    cat "$task/stack" 2>&1
  done
done
for stack in /proc/[0-9]*/stack; do
  pid=${stack#/proc/}
  pid=${pid%/stack}
  if [[ $(cat "/proc/$pid/comm" 2>/dev/null) != "Hyprland" ]] && grep -q 'virtio_gpu\|drm_' "$stack" 2>/dev/null; then
    echo "-- $(cat "/proc/$pid/comm") $pid"
    cat "$stack"
  fi
done
journalctl -k -b --no-pager | tail -n 80
LOOK
hyprland_look() {
  ssh_quick 60 "echo $GUEST_PASSWORD | sudo -S -p '' bash -c $(printf %q "$HYPRLAND_LOOK")" >"$RUN_DIR/hyprland-$1.txt" 2>&1 || true
}

vm_status() { qmp '"query-status"' | jq -r 'select(.return.status) | .return.status' 2>/dev/null | tail -n 1; }

# asleep <seconds>: until the box is suspended: QEMU says so in S3, and in
# s2idle the box stops answering. Prints which.
asleep() {
  local started=$SECONDS
  while (( SECONDS - started < $1 )); do
    if [[ $(vm_status) == "suspended" ]]; then
      echo "suspended (S3)"
      return 0
    fi
    if ! ssh_quick 10 true 2>/dev/null && ! ssh_quick 10 true 2>/dev/null; then
      echo "not answering (s2idle)"
      return 0
    fi
    sleep 2
  done
  return 1
}

# The box's power button: QEMU's wake from S3, or its ACPI power button from
# s2idle (logind ignores it once the box is awake).
power_button() {
  if [[ $(vm_status) == "suspended" ]]; then
    qmp '"system_wakeup"' >/dev/null
  else
    qmp '"system_powerdown"' >/dev/null
  fi
}

guest "agentv screen sleep-after 120" >"$RUN_DIR/screen.log" 2>&1 || true

# Sleep off, the TV off: the apps close after 2 minutes, home waits on its
# ambient screen, the output goes off, and the box stays up.
check "sleep is off by default" test "$(guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/home" | jq -r '.settings.sleepWhenOff')" = "false"
guest "agentv screen tv off" >>"$RUN_DIR/screen.log" 2>&1 || true
log "Waiting out the 2 minutes with the TV off and sleep off"
sleep 135
screen_status >"$RUN_DIR/status-off.json"
check "T13.1 with the TV off, home waits on its ambient screen" jq -e '.ambient == true' "$RUN_DIR/status-off.json"
check "T13.1 and the TV's output is off" jq -e '.output == "off"' "$RUN_DIR/status-off.json"
check "the hour (shortened) is up" jq -e '.sleep.due_in_s == 0' "$RUN_DIR/status-off.json"
check "T13.2 with sleep off, the box never suspends" test "$(entries)" = "0"

# Something holds an inhibitor that blocks sleep, as the owner, the way
# Omarchy's update does, which logind itself would let the owner past. It's
# up before sleep turns on, since the hour is already over.
guest "systemd-run --user --unit=t13-2-hold systemd-inhibit --what=sleep --mode=block --who=t13.2 '--why=holding sleep' sleep 600" >>"$RUN_DIR/screen.log" 2>&1 || true
sleep 2
guest "systemd-inhibit --list --no-pager" >"$RUN_DIR/inhibitors.txt" 2>&1 || true
check "the inhibitor is held" grep -q "t13.2" "$RUN_DIR/inhibitors.txt"
settings '{"sleepWhenOff":true}'
check "sleep turns on" test "$(guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/home" | jq -r '.settings.sleepWhenOff')" = "true"
sleep 45
check "T13.2 not while an inhibitor is held" test "$(entries)" = "0"
screen_log >"$RUN_DIR/screen-journal-held.log"
check "and the screen says who holds it" grep -q "not sleeping yet: t13.2 (holding sleep)" "$RUN_DIR/screen-journal-held.log"

# Let go: it sleeps.
guest "systemctl --user stop t13-2-hold" >>"$RUN_DIR/screen.log" 2>&1 || true
if how=$(asleep 90); then
  log "The box went to sleep: $how"
  check "T13.2 once the inhibitor is let go, the box suspends" true
else
  check "T13.2 once the inhibitor is let go, the box suspends" false
fi
capture_console "success-sleep-asleep" || true
sleep 10

# The power button wakes it, to the ambient screen.
power_button
wait_for_ssh 180 failure-sleep-wake-ssh-timeout || { check "the power button wakes the box" false; stop_vm; finish; }
# The shortened hour would put it back to sleep while the check looks, so
# it's longer until then.
guest "agentv screen sleep-after 900" >>"$RUN_DIR/screen.log" 2>&1 || true
sleep 5
check "the kernel went into a suspend and came out of it" test "$(entries)-$(exits)" = "1-1"
# The screen daemon notices at its next look, within 15 s, then looks for the
# TV for 10 s. A pointer that moves as the box wakes can end the ambient
# screen meanwhile, and it's back once the TV is found still off.
heard_wake() {
  screen_log >"$RUN_DIR/screen-journal-1.log"
  grep -q "the box woke from sleep" "$RUN_DIR/screen-journal-1.log"
}
# What the screen daemon did since the wake, from its own log: the last word
# on the output, and on the ambient screen.
since_wake() { sed -n '/the box woke from sleep/,$p' "$RUN_DIR/screen-journal-1.log"; }
last_output() { since_wake | grep -o "the TV's output is \(on\|off\)" | tail -n 1; }
last_ambient() { sed -n '/sleeping: /,$p' "$RUN_DIR/screen-journal-1.log" | grep -o "the ambient screen\( ends\)\?" | tail -n 1; }
settled() { heard_wake && [[ $(last_output) == "the TV's output is off" ]]; }
waited=$SECONDS
until heard_wake || (( SECONDS - waited > 45 )); do sleep 3; done
check "the screen daemon heard the box wake" heard_wake
until settled || (( SECONDS - waited > 75 )); do sleep 3; done
check "and with the TV still off, the output goes off again" settled
check "T13.2 the power button wakes it to the ambient screen" test "$(last_ambient)" = "the ambient screen"
screen_status >"$RUN_DIR/status-woken.json"
log "agentv screen status after the wake: $(head -c 300 "$RUN_DIR/status-woken.json" | tr '\n' ' ')"
jq -e '.ok == true' "$RUN_DIR/status-woken.json" >/dev/null 2>&1 || hyprland_look woken
check "and Hyprland still answers" jq -e '.ok == true' "$RUN_DIR/status-woken.json"
# Back to the shortened hour: awake longer than that by now, it sleeps again.
guest "agentv screen sleep-after 120" >>"$RUN_DIR/screen.log" 2>&1 || true

# Awake for the hour (shortened) again, it sleeps again, and a key wakes it.
if how=$(asleep 240); then
  log "The box went to sleep again: $how"
  check "after the hour awake, it sleeps again" true
else
  check "after the hour awake, it sleeps again" false
fi
sleep 10
press shift
wait_for_ssh 180 failure-sleep-key-ssh-timeout || { check "a key wakes the box" false; stop_vm; finish; }
sleep 5
check "T13.2 a key on the keyboard wakes it" test "$(entries)-$(exits)" = "2-2"
screen_status >"$RUN_DIR/status-woken-again.json"
jq -e '.ok == true' "$RUN_DIR/status-woken-again.json" >/dev/null 2>&1 || hyprland_look woken-again
check "and Hyprland still answers after the second wake" jq -e '.ok == true' "$RUN_DIR/status-woken-again.json"

settings '{"sleepWhenOff":false}'
guest "agentv screen tv on" >>"$RUN_DIR/screen.log" 2>&1 || true
screen_log >"$RUN_DIR/screen-journal.log"
ssh_guest "journalctl -k -b --no-pager -g 'PM: '" >"$RUN_DIR/kernel-pm.log" 2>&1 || true
stop_vm
finish
