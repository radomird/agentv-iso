#!/bin/bash
#
# The adult PIN on an installed box (ADR-009, S4.5). With a PIN set:
# agentv-pin-check, with no terminal as from Super+Ctrl+Home, asks on the
# TV's pad and refuses when it's cancelled or wrong; Settings → Omarchy
# desktop asks for it too; a guarded request without the PIN is refused; the
# user account can't read where it's kept. After a restart, a profile that
# doesn't ask for the PIN opens without it, and one that does (ADR-034) is
# locked until it's typed in, with keys from the virtual input device as the
# remote would.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-pin-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-pin-no-tv"; check "the TV session came up" false; stop_vm; finish; }

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

pin_status() {
  ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/pin" 2>/dev/null || true
}
# What's on the TV, read off the screen once, in ocr_finds' three ways: the
# pad's headline sits beside its digits, which a single block reading can
# miss on the VM's small screen.
says() {
  local found=0
  ocr_finds "$1" "$2" 0 || found=1
  capture_console "$1"
  return $found
}
# The pad on the TV, read off the screen, for up to <seconds>.
wait_pad() {
  local found=0
  ocr_finds "$1" "enter the adult pin" "$2" || found=1
  capture_console "$1"
  return $found
}

ssh_guest "curl -fsS -X PUT -H 'Content-Type: application/json' -d '{\"pin\":\"4826\"}' http://127.0.0.1:3000/api/pin" >"$RUN_DIR/set.json" 2>&1 || true
check "a PIN can be set" jq -e '.set == true and .locked == false' "$RUN_DIR/set.json"

# A guarded request without the PIN, such as installing tonight.
code=$(ssh_guest "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{\"version\":\"packages\"}' http://127.0.0.1:3000/api/updates/tonight" 2>/dev/null || true)
check "S4.5 installing tonight without the PIN is refused (HTTP $code)" test "$code" = "403"

# Where it's kept is the daemon's own: the user account can't read it.
unreadable() {
  ! ssh_guest "cat /var/lib/agentv/daemon/pin.json" >/dev/null 2>&1
}
hashed() {
  ssh_sudo "test -s /var/lib/private/agentv/daemon/pin.json && ! grep -q 4826 /var/lib/private/agentv/daemon/pin.json" >/dev/null 2>&1
}
check "S4.5 the user account can't read the PIN's hash" unreadable
check "it's there for the daemon, as a hash, not the PIN" hashed

# agentv-pin-check with no terminal asks on the TV. Cancelled, it refuses.
guest "agentv-pin-check desktop; echo exit=\$?" >"$RUN_DIR/check-cancel.log" 2>&1 &
asking=$!
before=$FAILURES
check "with no terminal, agentv-pin-check asks for the PIN on the TV (OCR)" wait_pad "success-pin-asked" 30
if (( FAILURES > before )); then
  log "What OCR read on the pad:"
  cat "$RUN_DIR/success-pin-asked.txt"
  print_screen "$RUN_DIR/.ocr.ppm"
fi
check "the pad says what it's for (OCR)" grep -Eqi "omarchy|desk" "$RUN_DIR/success-pin-asked.txt"
guest "agentv input key back" >"$RUN_DIR/input.log" 2>&1 || true
wait "$asking" || true
check "S4.5 cancelled on the TV, agentv-pin-check refuses" grep -q "exit=1" "$RUN_DIR/check-cancel.log"
check "and says it needs the PIN" grep -q "That needs the adult PIN." "$RUN_DIR/check-cancel.log"

# A wrong PIN is refused on the pad, and the right one lets it through.
guest "agentv-pin-check desktop; echo exit=\$?" >"$RUN_DIR/check-right.log" 2>&1 &
asking=$!
wait_pad "success-pin-asked-again" 30 || true
guest "agentv input key 0 0 0 0" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 2
check "S4.5 a wrong PIN is refused on the pad (OCR)" says "success-pin-wrong" "not the pin"
guest "agentv input key 4 8 2 6" >>"$RUN_DIR/input.log" 2>&1 || true
wait "$asking" || true
check "the right PIN on the pad lets agentv-pin-check through" grep -q "exit=0" "$RUN_DIR/check-right.log"

# Settings → Omarchy desktop asks too, and Back leaves the TV where it was.
guest "agentv screen settings desktop" >"$RUN_DIR/settings.json" 2>&1 || true
sleep 2
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 1
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
check "S4.5 Settings → Omarchy desktop asks for the PIN (OCR)" wait_pad "success-pin-desktop" 20
guest "agentv input key back" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 3
check "and without it, the TV session stays" test "$(front '.front.role // ""')" = "home"

# The box is set up, so it shows no welcome page as it starts: wait for a new
# boot, then for the TV session, not for the welcome page.
restart() {
  local boot started
  boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
  ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
  started=$SECONDS
  while [[ $(ssh_guest "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || echo "$boot") == "$boot" ]] && (( SECONDS - started < 120 )); do sleep 3; done
  wait_for_ssh 300 "failure-pin-reboot-$1-ssh-timeout" || { check "the box came back" false; stop_vm; finish; }
  check "the box restarted ($1)" test "$(ssh_guest "cat /proc/sys/kernel/random/boot_id")" != "$boot"
  wait_home 240 >/dev/null || true
}

# After a restart, a profile that doesn't ask for the PIN opens without it
# (ADR-034).
restart open
check "ADR-034 after a restart, a profile that doesn't ask for the PIN isn't locked" jq -e '.set == true and .locked == false' <<<"$(pin_status)"
started=$SECONDS
until says "success-pin-open" "installed" || (( SECONDS - started > 60 )); do sleep 3; done
check "ADR-034 and home is there, with no pad (OCR)" says "success-pin-open" "installed"

# The owner's profile asks for it now: after a restart the TV is locked,
# until the PIN.
owner=$(ssh_guest "curl -fsS http://127.0.0.1:3000/api/viewers" 2>/dev/null | jq -r '.active // empty')
grant=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"pin\":\"4826\"}' http://127.0.0.1:3000/api/pin/check" 2>/dev/null | jq -r '.grant // empty')
ssh_guest "curl -fsS -X PUT -H 'Content-Type: application/json' -H 'X-AgenTV-Grant: $grant' -d '{\"locked\":true}' http://127.0.0.1:3000/api/viewers/$owner" >"$RUN_DIR/lock-profile.json" 2>&1 || true
check "ADR-034 the owner's profile asks for the PIN to open" jq -e '.profile.locked == true' "$RUN_DIR/lock-profile.json"
restart locked
check "S4.5 after a restart the TV is locked" jq -e '.set == true and .locked == true' <<<"$(pin_status)"
check "S4.5 and shows the pad, not home (OCR)" wait_pad "success-pin-locked" 60
guest "agentv input key 4 8 2 6" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 3
check "the PIN typed with the remote unlocks it" jq -e '.locked == false' <<<"$(pin_status)"
started=$SECONDS
until says "success-pin-unlocked" "installed" || (( SECONDS - started > 30 )); do sleep 3; done
check "and home is back (OCR)" says "success-pin-unlocked" "installed"

ssh_sudo "journalctl -u agentv-daemon --no-pager" >"$RUN_DIR/daemon.log" 2>&1 || true
not_logged() {
  grep -q "a wrong pin" "$RUN_DIR/daemon.log" && ! grep -q 4826 "$RUN_DIR/daemon.log"
}
check "the daemon logged the wrong PIN, and never the PIN itself" not_logged

stop_vm
finish
