#!/bin/bash
#
# What Radomir saw of Omarchy on the NUC stays off the TV (ADR-029):
# Omarchy's invitations to pick an agent and install Voxtype are marked as
# offered, its keybinding and update notices are dismissed while its first
# run is on, the idle lock never asks for a password, the welcome page stays
# an app window when a terminal opens over it, and agentv update asks
# AgenTV's own question.

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

# No password on an idle TV, and nothing in the menu that suspends it.
check "Omarchy's idle lock is off, and the screensaver stays" \
  ssh_guest "jq -e '.idle.lock == 0 and .idle.screensaver > 0' .config/omarchy/shell.json"
check "suspend is out of Omarchy's menu" ssh_guest "test -f .local/state/omarchy/toggles/suspend-off"

# As on the NUC: a terminal opened over the TV takes the full screen, and the
# welcome page must not turn into a browser window with an address bar.
check "the TV is a Chromium app window" \
  ssh_guest "pgrep -af 'user-data-dir=/var/lib/agentv/chromium' | grep -q -- '--app='"
ssh_guest "export HYPRLAND_INSTANCE_SIGNATURE=\$(ls /run/user/\$(id -u)/hypr | head -n 1); hyprctl dispatch exec omarchy-launch-terminal" >/dev/null 2>&1 || true
sleep 5
ocr_screen >"$RUN_DIR/screen-with-terminal.txt" 2>/dev/null || true
capture_console "tv-with-terminal"
check "with a terminal over it, the TV shows no browser tabs or address bar" \
  bash -c "! grep -q '127.0.0.1' '$RUN_DIR/screen-with-terminal.txt'"

ssh_guest "bash -lc 'agentv-update-confirm' </dev/null" >"$RUN_DIR/update-question.txt" 2>&1 || true
cat "$RUN_DIR/update-question.txt"
check "agentv update asks AgenTV's question, with AgenTV's version" grep -q "AgenTV [0-9]" "$RUN_DIR/update-question.txt"
check "agentv update points at AgenTV's release notes" grep -q "What's new: https://github.com/.*/agentv-os/releases" "$RUN_DIR/update-question.txt"
check "nothing of Omarchy's update question is left" bash -c "! grep -qi 'omacom\|battery' '$RUN_DIR/update-question.txt'"

stop_vm
finish
