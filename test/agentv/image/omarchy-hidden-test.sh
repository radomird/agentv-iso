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
# Straight away, while a full-screen window would still show Chrome's bubble.
ocr_screen >"$RUN_DIR/screen-start.txt" 2>/dev/null || true
capture_console "tv-start"
check "no \"press Esc to exit full screen\" bubble on the TV" \
  bash -c "! grep -qi 'exit full' '$RUN_DIR/screen-start.txt'"
sleep 30
ocr_screen >"$RUN_DIR/screen.txt" 2>/dev/null || true
capture_console "omarchy-hidden"
check "no Omarchy first-run notice is on the TV (keybindings, update, agent, Voxtype)" \
  bash -c "! grep -Eqi 'keybinding|update system|default agent|voxtype' '$RUN_DIR/screen.txt'"

# No password on an idle TV, and nothing in the menu that suspends it.
check "Omarchy's idle lock is off, and the screensaver stays" \
  ssh_guest "jq -e '.idle.lock == 0 and .idle.screensaver > 0' .config/omarchy/shell.json"
check "suspend is out of Omarchy's menu" ssh_guest "test -f .local/state/omarchy/toggles/suspend-off"

check "the TV is a Chromium kiosk app window" \
  ssh_guest "pgrep -af 'user-data-dir=/var/lib/agentv/chromium' | grep -- '--kiosk' | grep -q -- '--app='"

# Esc is AgenTV's back key (ADR-008): it must not take the TV out of full
# screen, which would bring back Omarchy's bar with its clock and weekday.
press esc
sleep 3
ocr_screen >"$RUN_DIR/screen-after-esc.txt" 2>/dev/null || true
capture_console "tv-after-esc"
check "after Esc the TV is still the full-screen welcome page" \
  bash -c "grep -q 'TV setup starts here' '$RUN_DIR/screen-after-esc.txt' && ! grep -Eqi '(mon|tues|wednes|thurs|fri|satur|sun)day' '$RUN_DIR/screen-after-esc.txt'"

# As on the NUC: Super+Return opens a terminal over the TV, which takes the
# full screen, and the welcome page must not turn into a browser window with
# tabs and an address bar.
press meta_l-ret
sleep 5
check "Super+Return opened a terminal over the TV" ssh_guest "pgrep -u \$(id -u) -x foot >/dev/null"
ocr_screen >"$RUN_DIR/screen-with-terminal.txt" 2>/dev/null || true
capture_console "tv-with-terminal"
check "with a terminal over it, the TV shows no browser tabs or address bar" \
  bash -c "! grep -Eq '127\.0\.0\.1|AgenTV setup' '$RUN_DIR/screen-with-terminal.txt'"

ssh_guest "bash -lc 'agentv-update-confirm' </dev/null" >"$RUN_DIR/update-question.txt" 2>&1 || true
cat "$RUN_DIR/update-question.txt"
check "agentv update asks AgenTV's question, with AgenTV's version" grep -q "AgenTV [0-9]" "$RUN_DIR/update-question.txt"
check "agentv update points at AgenTV's release notes" grep -q "What's new: https://github.com/.*/agentv-os/releases" "$RUN_DIR/update-question.txt"
check "nothing of Omarchy's update question is left" bash -c "! grep -qi 'omacom\|battery' '$RUN_DIR/update-question.txt'"

stop_vm
finish
