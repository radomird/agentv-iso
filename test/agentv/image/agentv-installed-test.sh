#!/bin/bash
#
# AgenTV's packages are on the installed box (ADR-025): the ISO's build step
# put agentv and agentv-keyring in the same install as Omarchy's own package,
# pacman trusts AgenTV's key, and agentv runs. Boots the base image that
# upstream's test/integration left behind, like its own scenarios do.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

fingerprint=$(tr -d '[:space:]' <"$ROOT/configs/airootfs/usr/share/agentv-iso/key-fingerprint")

log "Booting the installed system"
start_vm_from_base
wait_for_ssh 300 failure-agentv-ssh-timeout || exit 1

check "Omarchy's own package is installed" ssh_guest "pacman -Q omarchy"
check "agentv and agentv-keyring are installed" ssh_guest "pacman -Q agentv agentv-keyring"
# Right after boot, root's pacman (the update check's) can have the keyring
# open, as a root gpg-agent did in agentv-iso #55's run, and a read as the
# box's own account fails while it does. So it's tried for up to 30 s.
trusts() {
  local started=$SECONDS
  until ssh_guest "pacman-key --list-keys $fingerprint" >/dev/null 2>&1; do
    (( SECONDS - started < 30 )) || return 1
    sleep 2
  done
}
check "pacman trusts AgenTV's key" trusts
check "agentv runs" ssh_guest "agentv version"
check "nothing of AgenTV's is in Omarchy's folder" \
  ssh_guest "! pacman -Ql agentv | grep -q ' /usr/share/omarchy/'"

ssh_guest "agentv version; pacman -Q omarchy agentv agentv-keyring" >"$RUN_DIR/versions.txt" 2>&1 || true
capture_console "success-agentv-installed"

stop_vm
finish
