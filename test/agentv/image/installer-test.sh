#!/bin/bash
#
# The installer's end, on Radomir's NUC the part that hung (ADR-029,
# omarchy-iso#125): the finish screen releases the installed system before
# its reboot, and with it released, reboots through sysrq without needing
# the USB stick. The live ISO doesn't log to the serial console, so the
# release's own note on the installed system is what shows it.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-installer-ssh-timeout || exit 1

check "the installer released the installed system before the reboot, so it rebooted without the stick" \
  ssh_guest "grep -q 'released this system before rebooting' /var/log/agentv-iso-release.log"
ssh_guest "cat /var/log/agentv-iso-release.log" >"$RUN_DIR/release.txt" 2>&1 || true

stop_vm
finish
