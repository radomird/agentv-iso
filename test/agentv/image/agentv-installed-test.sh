#!/bin/bash
#
# AgenTV's packages are on the installed box (ADR-025): the ISO's build put
# agentv and agentv-keyring in the root image beside Omarchy's own package,
# pacman trusts AgenTV's key, and agentv runs. Boots the base image that
# upstream's test/integration left behind, like its own scenarios do.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ssh.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

fingerprint=$(tr -d '[:space:]' <"$ROOT/configs/airootfs/usr/share/agentv-iso/key-fingerprint")

log "Booting the installed system"
start_vm_from_base
wait_for_ssh 300 failure-agentv-ssh-timeout || exit 1

check "Omarchy's own package is installed" ssh_guest "pacman -Q omarchy"
check "agentv and agentv-keyring are installed" ssh_guest "pacman -Q agentv agentv-keyring"
check "pacman has AgenTV's key" ssh_guest "pacman-key --list-keys $fingerprint"
# Trusted, not only there: the installer fills the box's keyring itself,
# from a list that has to name AgenTV's keyring (customize.sh), and a key
# that isn't signed by the box's own master key fails every update.
check "pacman trusts AgenTV's key fully" \
  ssh_guest "sudo gpg --homedir /etc/pacman.d/gnupg --with-colons --list-keys $fingerprint | awk -F: '\$1 == \"pub\" { print \$2 }' | grep -qx '[fu]'"
check "agentv runs" ssh_guest "agentv version"
check "nothing of AgenTV's is in Omarchy's folder" \
  ssh_guest "! pacman -Ql agentv | grep -q ' /usr/share/omarchy/'"

ssh_guest "agentv version; pacman -Q omarchy agentv agentv-keyring" >"$RUN_DIR/versions.txt" 2>&1 || true
capture_console "success-agentv-installed"

stop_vm
finish
