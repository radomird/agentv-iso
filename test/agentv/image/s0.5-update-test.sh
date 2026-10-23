#!/bin/bash
#
# S0.5: a box updates in place with agentv update, with no reinstall, and the
# snapshot from before the update is in the boot menu. The nightly run hands
# over a signed repository with a newer agentv in $AGENTV_TEST_UPDATE_REPO
# and its version in $AGENTV_TEST_UPDATE_VERSION. The box takes it from here
# over QEMU's network, and everything else from Omarchy's stable channel as
# it stands. Skips when there's no repository.
#
# The update runs while the TV is on, so it's also S1.6's update: nothing it
# does takes the screen from the TV (ADR-031).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

if [[ -z ${AGENTV_TEST_UPDATE_REPO:-} ]]; then
  log "No newer agentv to update to; skipping"
  exit 0
fi
base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

port=$((SSH_PORT + 2))
(cd "$AGENTV_TEST_UPDATE_REPO" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

start_vm_from_base
wait_for_ssh 300 failure-S0.5-ssh-timeout || exit 1

wait_tv 240 >/dev/null || true
home_pid=$(front '.apps[] | select(.role == "home") | .pid')

before=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
log "Installed: agentv $before; updating to $AGENTV_TEST_UPDATE_VERSION"

# A throwaway VM: let the test user use sudo without a password, as someone at
# the box would type theirs. The rule alone isn't enough: some of Omarchy's
# sudo calls still asked for one, so this does what upstream's own
# test/upgrade-test does, with a name that sorts after every other rule.
ssh_sudo "printf '%s\n' '$GUEST_USER ALL=(ALL:ALL) NOPASSWD: ALL' 'Defaults:$GUEST_USER !authenticate' >/etc/sudoers.d/zzz-agentv-test && chmod 440 /etc/sudoers.d/zzz-agentv-test"
if ! ssh_guest "sudo -k; sudo -n true && sudo -n -v" </dev/null; then
  ssh_sudo "ls -l /etc/sudoers.d; sudo -l -U $GUEST_USER" >"$RUN_DIR/sudo.txt" 2>&1 || true
  check "the test box lets sudo through without a password" false
  stop_vm
  finish
fi
ssh_sudo "install -d /etc/agentv && echo http://10.0.2.2:$port >/etc/agentv/repository"

# Snapshot 0 is the running system, not a snapshot.
snapshots() { ssh_sudo "snapper -c root --csvout list --columns number | awk -F, 'NR > 1 && \$1 != 0 { n++ } END { print n + 0 }'"; }
snapshots_before=$(snapshots)

# A login shell, as someone at the box has and as upstream's test uses: it's
# where Omarchy's environment, OMARCHY_PATH among it, comes from.
# OMARCHY_UPDATE_LOGGED skips Omarchy's script(1) wrapper, as upstream's test
# does, so the update has no terminal: its questions, such as the reboot one,
# report and move on instead of waiting for an answer.
update="timeout 2400 env OMARCHY_UPDATE_LOGGED=1 agentv update -y --untested"
ssh_guest "bash -lc $(printf %q "$update") </dev/null" >"$RUN_DIR/agentv-update.log" 2>&1 || true
tail -n 30 "$RUN_DIR/agentv-update.log"

after=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
check "S0.5 agentv update moved agentv to $AGENTV_TEST_UPDATE_VERSION (was $before, now $after)" \
  test "$after" = "$AGENTV_TEST_UPDATE_VERSION"
snapshots_after=$(snapshots)
check "S0.5 Omarchy's update took a snapshot first (snapshots: $snapshots_before before, $snapshots_after after)" \
  test "$snapshots_after" -gt "$snapshots_before"
check "S0.5 the snapshot is in the boot menu" \
  ssh_sudo "grep -qi snapshot /boot/limine.conf"
check "AgenTV's migrations ran from Omarchy's post-update hook" \
  grep -qE "AgenTV migration|No AgenTV migrations to run" "$RUN_DIR/agentv-update.log"

screen_status >"$RUN_DIR/screen-after-update.json"
check "S1.6 after an update in place, the home screen is still in front" \
  test "$(jq -r '.front.role' "$RUN_DIR/screen-after-update.json")" = "home"
check "S1.6 it's the same home screen: the update didn't restart it" \
  test "$(jq -r '.apps[] | select(.role == "home") | .pid' "$RUN_DIR/screen-after-update.json")" = "$home_pid"
check "S1.6 nothing the update opened is on the TV" \
  test "$(jq -r '[.windows[] | select(.workspace == "1" and .role != "home")] | length' "$RUN_DIR/screen-after-update.json")" = "0"
check "S1.6 after the update the screen shows the TV (OCR)" screen_shows_welcome "success-S1.6-after-update"

ssh_sudo "snapper -c root list" >"$RUN_DIR/snapshots.txt" 2>&1 || true
stop_vm
finish
