#!/bin/bash
#
# What Radomir saw of Omarchy on the NUC stays off the TV (ADR-029):
# Omarchy's invitations to pick an agent and install Voxtype are marked as
# offered, its keybinding and update notices are dismissed while its first
# run is on, the idle lock never asks for a password, and agentv update asks
# AgenTV's own question. The TV runs in AgenTV's own session (ADR-031), so
# Omarchy's terminal key opens nothing over it; s1.6-front-test.sh tries a
# terminal opened over it anyway.

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
  ssh_guest "pgrep -af 'user-data-dir=/var/lib/agentv/chromium-home' | grep -- '--kiosk' | grep -q -- '--app='"

# Esc is AgenTV's back key (ADR-008): it must not take the TV out of full
# screen, which would bring back Omarchy's bar with its clock and weekday.
press esc
sleep 3
capture_console "tv-after-esc"
check "after Esc the TV is still the full-screen welcome page" ocr_finds screen-after-esc "$WELCOME_TEXT" 15
check "and no bar with its weekday came back over it" \
  bash -c "! grep -Eqi '(mon|tues|wednes|thurs|fri|satur|sun)day' '$RUN_DIR/screen-after-esc.txt'"

# As on the NUC: Super+Return. On Omarchy's desktop it opened a terminal
# over the TV; in the TV session it opens nothing, and the TV stays as it is.
press meta_l-ret
sleep 5
check "Super+Return opens no terminal over the TV" ssh_guest "! pgrep -u \$(id -u) -x foot >/dev/null"
capture_console "tv-after-super-return"
check "after Super+Return the TV is still the welcome page" ocr_finds screen-after-super-return "$WELCOME_TEXT" 15
check "with no browser tabs or address bar" \
  bash -c "! grep -Eq '127\.0\.0\.1|AgenTV setup' '$RUN_DIR/screen-after-super-return.txt'"

ssh_guest "bash -lc 'agentv-update-confirm' </dev/null" >"$RUN_DIR/update-question.txt" 2>&1 || true
cat "$RUN_DIR/update-question.txt"
check "agentv update asks AgenTV's question, with AgenTV's version" grep -q "AgenTV [0-9]" "$RUN_DIR/update-question.txt"
check "agentv update points at AgenTV's release notes" grep -q "What's new: https://github.com/.*/agentv-os/releases" "$RUN_DIR/update-question.txt"
check "nothing of Omarchy's update question is left" bash -c "! grep -qi 'omacom\|battery' '$RUN_DIR/update-question.txt'"

stop_vm
finish
