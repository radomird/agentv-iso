#!/bin/bash
#
# Settings → Power → Restart on an installed box (ADR-033, S2.18): the TV
# opens Settings at Power, and keys choose Restart and answer its question,
# as the remote would. The box restarts through Omarchy's own command and
# comes back to home. The boot it left says nothing held it up: no stop job
# waited, and it was down within seconds of Restart.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-restart-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-restart-no-tv"; check "the TV session came up" false; stop_vm; finish; }

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
guest "agentv screen settings power" >"$RUN_DIR/settings.json" 2>&1 || true
check "agentv screen settings opens Settings at Power" jq -e '.ok == true' "$RUN_DIR/settings.json"
sleep 2
# OK on Power goes into it, where Restart comes first, and OK on Restart asks.
guest "agentv input key enter" >"$RUN_DIR/input.log" 2>&1 || true
sleep 1
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 2
capture_console "success-restart-question"
ocr_top "$RUN_DIR/success-restart-question.png" "$RUN_DIR/question.txt" || true
check "Restart asks first: restart the box? (OCR)" grep -qi "restart the box" "$RUN_DIR/question.txt"

# The answer: it goes at once.
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
chosen=$SECONDS
down=""
while (( SECONDS - chosen < 60 )); do
  if [[ $(ssh_guest "cat /proc/sys/kernel/random/boot_id" 2>/dev/null) != "$boot" ]]; then
    down=$(( SECONDS - chosen ))
    break
  fi
  sleep 0.5
done
check "the box went down within 20 s of Restart (${down:-over 60} s)" test "${down:-99}" -le 20

wait_for_ssh 300 failure-restart-reboot-ssh-timeout || { check "the box came back after Restart" false; stop_vm; finish; }
check "it came back as a new boot" test "$(ssh_guest "cat /proc/sys/kernel/random/boot_id")" != "$boot"

screen_home() {
  [[ $(front '.front.role // ""') == "home" ]] || return 1
  ocr_screen >"$RUN_DIR/$1.txt" 2>/dev/null || true
  capture_console "$1"
  grep -qi "installed" "$RUN_DIR/$1.txt"
}
started=$SECONDS
until screen_home "success-restart-home" || (( SECONDS - started > 240 )); do sleep 5; done
check "S2.18 Restart in Settings → Power comes back to home (OCR)" screen_home "success-restart-home"

# The boot it left: what the screen daemon did, and whether anything made
# the restart wait for a stop job.
guest "journalctl --user -b -1 --no-pager -o short-unix -u agentv-screen" >"$RUN_DIR/screen-before.log" 2>&1 || true
ssh_sudo "journalctl -b -1 --no-pager -o short-unix" >"$RUN_DIR/boot-before.log" 2>&1 || true
check "the screen daemon restarted the box from Settings → Power" grep -q "restarting the box from settings → power" "$RUN_DIR/screen-before.log"
grep -E "A stop job is running for|stop-sigterm' timed out|Stopping timed out|timed out\. Killing" "$RUN_DIR/boot-before.log" >"$RUN_DIR/slow-stops.txt" || true
cat "$RUN_DIR/slow-stops.txt"
check "nothing held the restart up: no stop job waited ($(wc -l <"$RUN_DIR/slow-stops.txt") lines in slow-stops.txt)" test ! -s "$RUN_DIR/slow-stops.txt"
asked=$(grep -m 1 "restarting the box from settings → power" "$RUN_DIR/screen-before.log" | cut -d' ' -f1 || true)
last=$(grep -E '^[0-9]+\.[0-9]+ ' "$RUN_DIR/boot-before.log" | tail -n 1 | cut -d' ' -f1 || true)
took=$(awk -v a="${asked:-0}" -v b="${last:-0}" 'BEGIN { if (a > 0 && b >= a) printf "%.1f", b - a; else print "?" }')
check "the box was down ${took} s after Restart, by its own journal (about 10 s, 12 at most)" awk -v t="$took" 'BEGIN { exit !(t != "?" && t <= 12) }'

stop_vm
finish
