#!/bin/bash
#
# One install for all of phase 1 (ADR-025): a box switched to edge with
# agentv channel edge takes edge's newest AgenTV with agentv update, from the
# real edge release, without waiting for the nightly run and without a
# reinstall. That's how the NUC follows each stage.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/repos.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-edge-switch-ssh-timeout || exit 1

# A throwaway VM: sudo without a password, set up the way upstream's own
# test/upgrade-test does, as someone at the box would type theirs.
ssh_sudo "printf '%s\n' '$GUEST_USER ALL=(ALL:ALL) NOPASSWD: ALL' 'Defaults:$GUEST_USER !authenticate' >/etc/sudoers.d/zzz-agentv-test && chmod 440 /etc/sudoers.d/zzz-agentv-test"

# A pull request's run points the box at its own packages (own-repo, Q137).
# This check is about the real channels, so that steps aside first.
ssh_sudo "rm -f /etc/agentv/repository"

before=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
log "Installed: agentv $before, on $(ssh_guest "bash -lc 'agentv channel'")"

ssh_guest "bash -lc 'agentv channel edge' </dev/null" >"$RUN_DIR/agentv-channel.log" 2>&1 || true
check "agentv channel edge switches the box to edge" test "$(ssh_guest "bash -lc 'agentv channel'")" = "edge"
check "pacman takes AgenTV from the edge release" ssh_guest "grep -A3 '^\[agentv\]' /etc/pacman.conf | grep -q '^Server = .*/edge$'"

# Edge may be in the middle of being published again (repos.sh): wait until
# the box reads it, so agentv update's own sync finds it whole.
check "the box reads its package repositories, edge among them" sync_repos
tail -n 5 "$RUN_DIR/sync.log"

# A login shell, as someone at the box has. No --untested: on edge, agentv
# update doesn't wait for the nightly run by itself.
update="timeout 2400 env OMARCHY_UPDATE_LOGGED=1 agentv update -y"
ssh_guest "bash -lc $(printf %q "$update") </dev/null" >"$RUN_DIR/agentv-update.log" 2>&1 || true
tail -n 20 "$RUN_DIR/agentv-update.log"

edge=$(ssh_guest "pacman -Sl agentv" | awk '$2 == "agentv" { print $3 }')
after=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
check "edge doesn't wait for the nightly run" grep -q "^On edge: taking AgenTV's newest green build" "$RUN_DIR/agentv-update.log"
check "Omarchy's update finished" bash -c "! grep -q 'Something went wrong during the update' '$RUN_DIR/agentv-update.log'"
# pacman keeps a newer local build, such as a pull request's, so at least.
check "the box is on edge's newest agentv or newer (was $before, now $after, edge has ${edge:-nothing})" \
  ssh_guest "[[ -n '$edge' ]] && (( \$(vercmp '$after' '$edge') >= 0 ))"

stop_vm
finish
