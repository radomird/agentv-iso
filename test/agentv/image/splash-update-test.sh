#!/bin/bash
#
# AgenTV's logo on the boot splash from the very first boot, and still there
# after Omarchy's settings package updates (ADR-021, ADR-029). Omarchy's
# splash belongs to omarchy-settings, which puts Omarchy's logo back each
# time it's installed; AgenTV's pacman hook puts AgenTV's back and rebuilds
# the boot image.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/repos.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-splash-update-ssh-timeout || exit 1

check "AgenTV's splash hook ran while the installer put the packages down" \
  ssh_sudo "grep -q \"running '60-agentv-splash.hook'\" /var/log/pacman.log"

# The test box has never synced its package databases. It does that first,
# waiting out an edge release that's being published again (repos.sh).
check "the box reads its package repositories" sync_repos
tail -n 5 "$RUN_DIR/sync.log"

# A marker from before the reinstall, so "rebuilt" means rebuilt by it.
ssh_sudo "touch /root/before-omarchy-settings"
ssh_sudo "pacman -S --noconfirm omarchy-settings" >"$RUN_DIR/omarchy-settings.log" 2>&1 || true
tail -n 15 "$RUN_DIR/omarchy-settings.log"
check "omarchy-settings was reinstalled, and AgenTV's hook ran after it" \
  grep -q "Putting AgenTV's logo on the boot splash" "$RUN_DIR/omarchy-settings.log"
check "after an Omarchy settings update, the splash is still AgenTV's logo" \
  ssh_sudo "cmp -s /usr/share/agentv/branding/plymouth-logo.png /usr/share/plymouth/themes/omarchy/logo.png"
check "and the boot image was rebuilt with it" \
  ssh_sudo "[ -n \"\$(find /boot -name '*.efi' -newer /root/before-omarchy-settings | head -n 1)\" ]"

stop_vm
finish
