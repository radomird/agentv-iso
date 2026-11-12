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
# Right after boot, root's pacman (the update check's) can have the keyring
# open, as a root gpg-agent did in one image run, and a read as the box's
# own account fails while it does. So it's tried for up to 30 s.
has_key() {
  local started=$SECONDS
  until ssh_guest "pacman-key --list-keys $fingerprint" >/dev/null 2>&1; do
    (( SECONDS - started < 30 )) || return 1
    sleep 2
  done
}
check "pacman has AgenTV's key" has_key
# Trusted, not only there: the installer fills the box's keyring itself,
# from a list that has to name AgenTV's keyring (customize.sh), and a key
# that isn't signed by the box's own master key fails every update.
ssh_sudo "gpg --homedir /etc/pacman.d/gnupg --with-colons --list-keys $fingerprint" >"$RUN_DIR/agentv-key.txt" 2>&1 || true
check "pacman trusts AgenTV's key fully" \
  test "$(awk -F: '$1 == "pub" { print $2; exit }' "$RUN_DIR/agentv-key.txt")" = f -o "$(awk -F: '$1 == "pub" { print $2; exit }' "$RUN_DIR/agentv-key.txt")" = u
# AgenTV's keyring names AgenTV's key and no other. A pull request's run is
# the one exception: its packages are signed with a throwaway key made for
# the run (agentv-os's image.yml), and its own agentv-keyring names that one
# too. A box installed from a channel must never have a second key.
expected=$fingerprint
if [[ -n ${AGENTV_TEST_PACKAGE_KEY:-} ]]; then
  expected+=" $(gpg --batch --with-colons --show-keys "$AGENTV_TEST_PACKAGE_KEY" | awk -F: '$1 == "fpr" { print $10; exit }')"
fi
trusted=$(ssh_guest "cut -d: -f1 /usr/share/pacman/keyrings/agentv-trusted | paste -sd' '" 2>/dev/null || true)
check "AgenTV's keyring trusts the keys it should, and no other (it has: ${trusted:-none})" test "$trusted" = "$expected"
check "agentv runs" ssh_guest "agentv version"
# The box has the agentv package the ISO was built with, and says so. A
# release's ISO is named after its version (agentv-1.0.0-x86_64.iso), so
# what "agentv version" prints on a box installed from it has to be that
# package's version. Checked wherever the packages the build read are still
# beside this check: always in this repo's own ISO run, which is the one a
# release tag starts. A job that was only handed the installed box doesn't
# have them, and says it skipped this.
carried=("$ROOT"/configs/airootfs/usr/share/agentv-iso/packages/agentv-[0-9]*-any.pkg.tar.zst)
if [[ ${#carried[@]} == 1 && -f ${carried[0]} ]]; then
  package=${carried[0]##*/agentv-}
  package=${package%-any.pkg.tar.zst}
  installed=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
  check "the box has the agentv the ISO was built with ($package, and it has ${installed:-none})" test "$installed" = "$package"
  said=$(ssh_guest "agentv version" | head -n 1 | cut -d' ' -f2)
  check "and agentv version says so (${package%-*}, and it says ${said:-nothing})" test "$said" = "${package%-*}"
else
  log "The packages the ISO was built with aren't here, so the box's agentv isn't compared with them"
fi
# AgenTV's repository takes its package list only with the signature. A box
# straight from the ISO has no list yet, and one that has refreshed has both.
# A list alone would make pacman refuse every install that doesn't refresh.
check "AgenTV's package list is never on the box without its signature" \
  ssh_guest "[[ ! -e /var/lib/pacman/sync/agentv.db || -s /var/lib/pacman/sync/agentv.db.sig ]]"
check "pacman reads its package lists without an error about AgenTV's" \
  ssh_guest "! pacman -Si agentv 2>&1 | grep -qi 'signature\|not valid'"
check "nothing of AgenTV's is in Omarchy's folder" \
  ssh_guest "! pacman -Ql agentv | grep -q ' /usr/share/omarchy/'"

ssh_guest "agentv version; pacman -Q omarchy agentv agentv-keyring" >"$RUN_DIR/versions.txt" 2>&1 || true
capture_console "success-agentv-installed"

stop_vm
finish
