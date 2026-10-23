#!/bin/bash
#
# What Radomir saw of Omarchy on the NUC's first boot stays off the TV
# (ADR-029): Omarchy's invitations to pick an agent and install Voxtype are
# marked as offered, its keybinding and update notices are dismissed while
# its first run is on, and agentv update asks AgenTV's own question.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-omarchy-hidden-ssh-timeout || exit 1

done_dir=".local/state/omarchy/done"
check "first boot marked Omarchy's agent, Voxtype and fingerprint invitations as offered" \
  ssh_guest "test -f $done_dir/agent-setup-invitation -a -f $done_dir/voxtype-install-invitation -a -f $done_dir/fingerprint-setup-invitation"
log "Omarchy's first run is $(ssh_guest "test -f $done_dir/first-run-user && echo done || echo still on")"

# The welcome page, then long enough for Omarchy's first run to send its
# notices and for AgenTV to dismiss them.
for _ in $(seq 1 60); do
  ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/health | jq -e .welcome_shown >/dev/null" && break
  sleep 2
done
sleep 30
ocr_screen >"$RUN_DIR/screen.txt" 2>/dev/null || true
capture_console "omarchy-hidden"
check "no Omarchy first-run notice is on the TV (keybindings, update, agent, Voxtype)" \
  bash -c "! grep -Eqi 'keybinding|update system|default agent|voxtype' '$RUN_DIR/screen.txt'"

ssh_guest "bash -lc 'agentv-update-confirm' </dev/null" >"$RUN_DIR/update-question.txt" 2>&1 || true
cat "$RUN_DIR/update-question.txt"
check "agentv update asks AgenTV's question, with AgenTV's version" grep -q "AgenTV [0-9]" "$RUN_DIR/update-question.txt"
check "agentv update points at AgenTV's release notes" grep -q "What's new: https://github.com/.*/agentv-os/releases" "$RUN_DIR/update-question.txt"
check "nothing of Omarchy's update question is left" bash -c "! grep -qi 'omacom\|battery' '$RUN_DIR/update-question.txt'"

stop_vm
finish
