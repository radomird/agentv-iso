#!/bin/bash
#
# S5.6: TV setup started on a box from an older build brings itself up to
# date at getting ready, the screens after it come from the new release, and
# setup picks up at the same step after a restart (ADR-025, board 35).
#
# The box starts on the welcome screen. Enter carries on with the keyboard,
# as the VM is online on its cable. At getting ready the screen daemon's
# update check finds the newer agentv this image run hands over, and the
# TV's own install puts it on. AgenTV restarts on it, or the box does when
# the update needs that, and setup carries on from the new release to what
# the TV is for. A restart there comes back to the same step, and Enter on
# it finishes setup. With no newer agentv, getting ready finds nothing to
# install and moves on, and the rest is the same.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

if [[ -n ${AGENTV_TEST_UPDATE_REPO:-} ]]; then
  port=$((SSH_PORT + 3))
  (cd "$AGENTV_TEST_UPDATE_REPO" && exec python3 -m http.server --bind 127.0.0.1 "$port") >/dev/null 2>&1 &
  server=$!
  trap 'kill "$server" 2>/dev/null || true' EXIT
fi

# until_setup <jq filter> <seconds>: until the filter on what the setup
# screens hear (/api/setup) is true.
until_setup() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/setup" 2>/dev/null | jq -r "$1" 2>/dev/null) == "true" ]] && return 0
    sleep 2
  done
  return 1
}

# until_file <jq filter> <file> <seconds>: until the filter is true.
until_file() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "cat $2 2>/dev/null" | jq -r "$1" 2>/dev/null) == "true" ]] && return 0
    sleep 3
  done
  return 1
}

start_vm_from_base
wait_for_ssh 300 failure-S5.6-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true

check "setup starts on the welcome screen" until_setup '.setup.step == "welcome" and (.setup.done | not)' 30
check "the welcome screen is on the TV (OCR)" screen_shows_welcome "success-S5.6-welcome"
before=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
if [[ -n ${AGENTV_TEST_UPDATE_REPO:-} ]]; then
  # The newer agentv this run hands over, on edge, where it doesn't wait for
  # the nightly run (ADR-026).
  ssh_sudo "install -d /etc/agentv && echo http://10.0.2.2:$port >/etc/agentv/repository && echo edge >/etc/agentv/channel"
fi

guest "agentv input key enter" >"$RUN_DIR/input.log" 2>&1 || true
check "Enter on the welcome screen carries on with the keyboard, to getting ready" until_setup '.setup.step == "ready" and .setup.keyboard' 60
check "getting ready is on the TV (OCR)" ocr_finds success-S5.6-getting-ready "getting ready" 30
capture_console "success-S5.6-getting-ready"

if [[ -n ${AGENTV_TEST_UPDATE_REPO:-} ]]; then
  check "S5.6 getting ready finds agentv $AGENTV_TEST_UPDATE_VERSION and starts the TV's own install" \
    until_setup ".setup.ready.update == \"installing\" and .setup.ready.to == \"$AGENTV_TEST_UPDATE_VERSION\"" 300
  ssh_guest "curl -fsS http://127.0.0.1:3000/api/setup" >"$RUN_DIR/setup-installing.json" 2>&1 || true
  boot_id=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
  log "Waiting for the update to finish"
  until_file '.state != "running"' /var/lib/agentv/update/progress.json 2400 || true
  ssh_guest "cat /var/lib/agentv/update/progress.json" >"$RUN_DIR/progress.json" 2>&1 || true
  check "S5.6 the update finishes ($(jq -r '"\(.state): \(.detail)"' "$RUN_DIR/progress.json" 2>/dev/null))" \
    jq -e '.state == "done" or .state == "restarting"' "$RUN_DIR/progress.json"
  if [[ $(jq -r .state "$RUN_DIR/progress.json") == "restarting" ]]; then
    log "The update restarts the box"
    sleep 20
    wait_for_ssh 300 failure-S5.6-update-reboot-ssh-timeout || exit 1
    wait_tv 240 >/dev/null || true
  else
    took=$(wait_running "$AGENTV_TEST_UPDATE_VERSION" 120) || took=""
    check "S5.6 the screens after it come from the new release: the daemon, the screen daemon and setup's page run agentv $AGENTV_TEST_UPDATE_VERSION${took:+ (after $took s)}" \
      test -n "$took"
    check "and the box didn't restart for it" test "$(ssh_guest "cat /proc/sys/kernel/random/boot_id")" = "$boot_id"
  fi
  after=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
  check "S5.6 the box is on agentv $AGENTV_TEST_UPDATE_VERSION (was $before, now $after)" test "$after" = "$AGENTV_TEST_UPDATE_VERSION"
  check "S5.6 the daemon setup talks to runs the new release" test "$(jq -r '.running // ""' <<<"$(health)")" = "$AGENTV_TEST_UPDATE_VERSION"
  check "S5.6 getting ready sees the update in, and setup moves on to what the TV is for" \
    until_setup '.setup.ready.update == "done" and .setup.step == "goal"' 180
else
  log "No newer agentv to update to; getting ready finds nothing to install"
  check "with nothing newer, getting ready moves on to what the TV is for" \
    until_setup '(.setup.ready.update == "none" or .setup.ready.update == "failed") and .setup.step == "goal"' 400
fi
ssh_guest "curl -fsS http://127.0.0.1:3000/api/setup" >"$RUN_DIR/setup-goal.json" 2>&1 || true
check "what the TV is for is on the TV (OCR)" ocr_finds success-S5.6-goal "pick one|what is this tv for" 30
capture_console "success-S5.6-goal"

# A restart: setup comes back at the same step.
boot_id=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
sleep 20
wait_for_ssh 300 failure-S5.6-restart-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
check "the box restarted" test "$(ssh_guest "cat /proc/sys/kernel/random/boot_id")" != "$boot_id"
check "S5.6 after a restart, setup picks up at the same step" until_setup '.setup.step == "goal" and (.setup.done | not)' 60
check "S5.6 /health says so too" test "$(jq -r '.setup_step // ""' <<<"$(health)")" = "goal"
check "S5.6 and the TV shows that step again (OCR)" ocr_finds success-S5.6-goal-after-restart "pick one|what is this tv for" 30
capture_console "success-S5.6-goal-after-restart"

# Enter picks the first one, and setup is done: home takes over.
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
check "Enter on what the TV is for finishes setup, and home takes over" until_setup '.setup.done and .setup.goal == "streaming"' 60
took=$(wait_home 60) || took=""
check "home is in front${took:+ (after $took s)}" test -n "$took"
check "and /health says home" test "$(jq -r '.screen // ""' <<<"$(health)")" = "home"
capture_console "success-S5.6-home"

stop_vm
finish
