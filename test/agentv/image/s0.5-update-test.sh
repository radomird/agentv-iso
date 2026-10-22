#!/bin/bash
#
# S0.5: a box updates in place with agentv update, with no reinstall, and the
# snapshot from before the update is in the boot menu. The nightly run hands
# over a signed repository with a newer agentv in $AGENTV_TEST_UPDATE_REPO
# and its version in $AGENTV_TEST_UPDATE_VERSION. The box takes it from here
# over QEMU's network, and everything else from Omarchy's stable channel as
# it stands. Skips when there's no repository.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"

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

before=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
log "Installed: agentv $before; updating to $AGENTV_TEST_UPDATE_VERSION"

# A throwaway VM: let the test user use sudo without a password, as someone at
# the box would type theirs, and point AgenTV's repository at the test one.
ssh_sudo "echo '$GUEST_USER ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/zz-test && chmod 440 /etc/sudoers.d/zz-test"
ssh_sudo "install -d /etc/agentv && echo http://10.0.2.2:$port >/etc/agentv/repository"

# Nobody answers Omarchy's reboot question here, so it doesn't reboot.
ssh_guest "timeout 2400 agentv update -y --untested </dev/null" >"$RUN_DIR/agentv-update.log" 2>&1 || true
tail -n 30 "$RUN_DIR/agentv-update.log"

after=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
check "S0.5 agentv update moved agentv to $AGENTV_TEST_UPDATE_VERSION (was $before, now $after)" \
  test "$after" = "$AGENTV_TEST_UPDATE_VERSION"
check "S0.5 Omarchy's update took a snapshot first" \
  ssh_sudo "snapper -c root list --columns number,type,description | grep -qiE 'pre|update'"
check "S0.5 the snapshot is in the boot menu" \
  ssh_sudo "grep -qi snapshot /boot/limine.conf"
check "AgenTV's migrations ran from Omarchy's post-update hook" \
  grep -qE "AgenTV migration|No AgenTV migrations to run" "$RUN_DIR/agentv-update.log"

ssh_sudo "snapper -c root list" >"$RUN_DIR/snapshots.txt" 2>&1 || true
stop_vm
finish
