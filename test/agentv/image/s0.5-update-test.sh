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
# does takes the screen from the TV (ADR-031). It ends by restarting
# AgenTV's own services on the new agentv (agentv-restart), so home comes
# back on the new version, with no restart of the box unless it has a new
# kernel or Omarchy's update says it needs one.

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
boot_id=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")

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

if needs_restart; then
  # A new kernel came with Omarchy's packages, or its update set its flag.
  log "This update needs a restart of the box, so AgenTV's services start again with it"
  check "the update leaves AgenTV's services to the restart it needs" \
    grep -q "AgenTV's services start again with the box" "$RUN_DIR/agentv-update.log"
  check "S1.6 after an update in place, the home screen is still in front" wait_tv 60
else
  check "the update restarted AgenTV's services" grep -q "Restarting AgenTV's services" "$RUN_DIR/agentv-update.log"
  took=$(wait_running "$AGENTV_TEST_UPDATE_VERSION" 90) || took=""
  check "S1.6 after an update in place, home is back in front, and AgenTV's daemon and screen daemon run agentv $AGENTV_TEST_UPDATE_VERSION${took:+ (after $took s)}" \
    test -n "$took"
  health >"$RUN_DIR/health-after-update.json"
  cat "$RUN_DIR/health-after-update.json"
  echo
  home_after=$(front '.apps[] | select(.role == "home") | .pid')
  # No home screen at all counts as the same one.
  check "the home screen restarted with them (pid $home_pid before, ${home_after:-none} now)" \
    test "${home_after:-$home_pid}" != "$home_pid"
  check "and the box didn't restart" test "$(ssh_guest "cat /proc/sys/kernel/random/boot_id")" = "$boot_id"
fi
screen_status >"$RUN_DIR/screen-after-update.json"
cat "$RUN_DIR/screen-after-update.json"
check "S1.6 nothing the update opened is on the TV" \
  test "$(jq -r '[.windows[] | select(.workspace == "1" and .role != "home")] | length' "$RUN_DIR/screen-after-update.json")" = "0"
check "S1.6 after the update the screen shows the TV (OCR)" screen_shows_welcome "success-S1.6-after-update"

ssh_sudo "snapper -c root list" >"$RUN_DIR/snapshots.txt" 2>&1 || true
stop_vm
finish
