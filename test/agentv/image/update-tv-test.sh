#!/bin/bash
#
# Updates from the TV (ADR-025, S2.12): Settings → Updates' Check now finds the
# newer agentv the image run hands over, and Install now installs it, with the
# TV's Updating screen on while it runs, then home again on the new release.
# Both go through the TV's screen daemon, as the launcher's buttons do
# (agentv screen update check|install), and through polkit. Skips when
# there's no newer agentv, as S0.5 does.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

if [[ -z ${AGENTV_TEST_UPDATE_REPO:-} ]]; then
  log "No newer agentv to update to; skipping"
  exit 0
fi
base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

port=$((SSH_PORT + 3))
(cd "$AGENTV_TEST_UPDATE_REPO" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

start_vm_from_base
wait_for_ssh 300 failure-update-tv-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
ssh_sudo "install -d /etc/agentv && echo http://10.0.2.2:$port >/etc/agentv/repository"
before=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)

# until_file <jq filter> <file> <seconds>: until the filter is true.
until_file() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "cat $2 2>/dev/null" | jq -r "$1" 2>/dev/null) == "true" ]] && return 0
    sleep 3
  done
  return 1
}

# The agentv this run hands over isn't in the nightly run's tested.json, so
# on stable it waits (ADR-026), and Check now says so. On edge it goes ahead,
# the way S0.5's check takes it with --untested.
guest "agentv screen update check" >"$RUN_DIR/screen.log" 2>&1 || true
check "S2.12 on stable, Check now says agentv $AGENTV_TEST_UPDATE_VERSION waits for the nightly run" \
  until_file ".agentv.available == \"$AGENTV_TEST_UPDATE_VERSION\" and .waiting == true" /var/lib/agentv/update/status.json 180
ssh_sudo "echo edge >/etc/agentv/channel"
guest "agentv screen update check" >>"$RUN_DIR/screen.log" 2>&1 || true
check "S2.12 Check now finds agentv $AGENTV_TEST_UPDATE_VERSION" \
  until_file ".channel == \"edge\" and .agentv.available == \"$AGENTV_TEST_UPDATE_VERSION\" and .waiting == false" /var/lib/agentv/update/status.json 180
ssh_guest "cat /var/lib/agentv/update/status.json" >"$RUN_DIR/status.json" 2>&1 || true
check "S2.12 and says which agentv the box has now" \
  test "$(jq -r '.agentv.installed' "$RUN_DIR/status.json")" = "$before"

guest "agentv screen update install" >>"$RUN_DIR/screen.log" 2>&1 || true
check "S2.12 Install now starts the update" \
  until_file '.state == "running"' /var/lib/agentv/update/progress.json 60
sleep 5
ocr_screen >"$RUN_DIR/success-update-tv-updating.txt" 2>/dev/null || true
capture_console "success-update-tv-updating"
check "S2.12 the TV shows the Updating screen (OCR)" grep -qi "updating to agentv" "$RUN_DIR/success-update-tv-updating.txt"

log "Waiting for the update to finish"
until_file '.state != "running"' /var/lib/agentv/update/progress.json 2400 || true
ssh_guest "cat /var/lib/agentv/update/progress.json" >"$RUN_DIR/progress.json" 2>&1 || true
check "S2.12 the update finishes ($(jq -r '"\(.state): \(.detail)"' "$RUN_DIR/progress.json" 2>/dev/null))" \
  jq -e '.state == "done" or .state == "restarting"' "$RUN_DIR/progress.json"
ssh_guest "cat /var/lib/agentv/update/update.log" >"$RUN_DIR/update.log" 2>&1 || true
jq -e '.state == "done" or .state == "restarting"' "$RUN_DIR/progress.json" >/dev/null 2>&1 || tail -n 30 "$RUN_DIR/update.log"
if [[ $(jq -r .state "$RUN_DIR/progress.json") == "restarting" ]]; then
  log "The update restarts the box"
  sleep 20
  wait_for_ssh 300 failure-update-tv-reboot-ssh-timeout || exit 1
fi

after=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
check "S2.12 the box is on agentv $AGENTV_TEST_UPDATE_VERSION (was $before, now $after)" test "$after" = "$AGENTV_TEST_UPDATE_VERSION"
check "the owner's sudo goes back to asking for a password" ssh_sudo "! ls /etc/sudoers.d/99-omarchy-nopasswd-* 2>/dev/null | grep -q ."
screen_home() {
  ocr_screen >"$RUN_DIR/$1.txt" 2>/dev/null || true
  capture_console "$1"
  grep -qi "installed" "$RUN_DIR/$1.txt"
}
started=$SECONDS
until screen_home "success-update-tv-home" || (( SECONDS - started > 120 )); do sleep 5; done
check "S2.12 the TV is back on home after the update (OCR)" screen_home "success-update-tv-home"

stop_vm
finish
