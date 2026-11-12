#!/bin/bash
#
# Settings → This TV → Shut down on an installed box (ADR-033, S2.18): the TV
# opens Settings at This TV, and keys choose Shut down and answer its question,
# as the remote would. It counts down 10 seconds, then the box turns off
# through Omarchy's own command, and the VM is off within 20 s of choosing
# Shut down, countdown included. When it takes longer, the box is started
# again to say which stop job held it up.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-shutdown-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-shutdown-no-tv"; check "the TV session came up" false; stop_vm; finish; }

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

# Setup being done loads home's page again, and Settings opens only once
# it's back, which a VM with no GPU can take longer than the 5 s above to
# draw: on 2026-11-01 the screen was still black 12 s after, and the keys
# went nowhere. So ask until home answers, for up to a minute.
for _ in $(seq 1 30); do
  guest "agentv screen settings power" >"$RUN_DIR/settings.json" 2>&1 || true
  jq -e '.ok == true' "$RUN_DIR/settings.json" >/dev/null 2>&1 && break
  sleep 2
done
check "agentv screen settings opens Settings at Power" jq -e '.ok == true' "$RUN_DIR/settings.json"
sleep 2
# OK on This TV goes into it at Restart, down to Shut down, and OK on it asks.
for key in enter down enter; do
  guest "agentv input key $key" >>"$RUN_DIR/input.log" 2>&1 || true
  sleep 1
done
sleep 1
capture_console "success-shutdown-question"
ocr_top "$RUN_DIR/success-shutdown-question.png" "$RUN_DIR/question.txt" || true
# The question's page: "tv power shutdown" over "shut down?".
check "Shut down asks first: shut down? (OCR)" grep -Eqi "shut ?down" "$RUN_DIR/question.txt"

# The answer starts the countdown.
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
chosen=$(date +%s%N)
sleep 3
capture_console "success-shutdown-countdown"
ocr_top "$RUN_DIR/success-shutdown-countdown.png" "$RUN_DIR/countdown.txt" || true
check "it counts down: shutting down (OCR)" grep -qi "shutting down" "$RUN_DIR/countdown.txt"
check "and the box is still on while it counts" vm_running

while vm_running && (( ($(date +%s%N) - chosen) / 1000000000 < 60 )); do sleep 0.2; done
took_ms=$(( ($(date +%s%N) - chosen) / 1000000 ))
took=$(awk -v ms="$took_ms" 'BEGIN { printf "%.1f", ms / 1000 }')
if vm_running; then
  check "S2.18 Shut down in Settings → Power turned the box off (still on after 60 s)" false
  stop_vm
  finish
fi
check "S2.18 Shut down in Settings → Power turned the box off $took s after it was chosen: the 10 s countdown, then off within 20 s" \
  test "$took_ms" -ge 9500 -a "$took_ms" -le 20000

# Slower than that: start the box again and find the stop job that waited.
if (( took_ms > 20000 )); then
  start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/serial-after.log"
  if wait_for_ssh 300 failure-shutdown-after-ssh-timeout; then
    ssh_sudo "journalctl -b -1 --no-pager" >"$RUN_DIR/boot-before.log" 2>&1 || true
    grep -E "A stop job is running for|stop-sigterm' timed out|Stopping timed out|timed out\. Killing" "$RUN_DIR/boot-before.log" >"$RUN_DIR/slow-stops.txt" || true
    echo "What held the shut down up:"
    cat "$RUN_DIR/slow-stops.txt"
  fi
  stop_vm
fi
finish
