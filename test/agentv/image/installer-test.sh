#!/bin/bash
#
# The installer's end, on Radomir's NUC the part that hung (ADR-029,
# omarchy-iso#125): the finish screen releases the installed system before
# its reboot and reboots without needing the USB stick. The reboot itself
# shows in the install's serial log, the release on the installed system.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

install_run=$(find "$BASE_DIR/runs" -maxdepth 1 -type d -name '*-install' 2>/dev/null | sort | tail -n 1)
check "the install's serial log is there (${install_run:-none})" test -s "$install_run/install-serial.log"
check "the finish screen rebooted through sysrq, which needs nothing from the USB stick" \
  grep -aq "sysrq: Resetting" "$install_run/install-serial.log"

start_vm_from_base
wait_for_ssh 300 failure-installer-ssh-timeout || exit 1

check "the installer released the installed system before the reboot" \
  ssh_guest "test -s /var/log/agentv-iso-release.log"
ssh_guest "cat /var/log/agentv-iso-release.log" >"$RUN_DIR/release.txt" 2>&1 || true

stop_vm
finish
