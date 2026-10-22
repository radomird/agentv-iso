#!/bin/bash
#
# S0.4: the installer, the boot splash and the screensaver show AgenTV's logo,
# with "powered by omarchy" under it in the installer (ADR-021). That no file
# of Omarchy's is edited for it is the Check workflow's half.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# The installer: the install dashboard, in the screenshots the unattended
# install took every two minutes.
screen_says() {
  tesseract "$1" - 2>/dev/null | grep -qi "$2"
}
installer_shows_logo() {
  local shot

  for shot in "$BASE_DIR"/runs/*-install/success-install-*.png; do
    [[ -f $shot ]] || continue
    if screen_says "$shot" "powered by omarchy"; then
      cp "$shot" "$RUN_DIR/success-S0.4-installer.png"
      return 0
    fi
  done
  return 1
}
check "S0.4 the installer shows AgenTV's logo, powered by omarchy (OCR)" installer_shows_logo

log "Booting the installed system"
start_vm_from_base
wait_for_ssh 300 failure-S0.4-ssh-timeout || exit 1

check "S0.4 the boot splash is AgenTV's logo" \
  ssh_sudo "cmp -s /usr/share/plymouth/themes/omarchy/logo.png /usr/share/agentv/branding/plymouth-logo.png"
check "S0.4 the screensaver is AgenTV's logo" \
  ssh_guest "cmp -s ~/.config/omarchy/branding/screensaver.txt /usr/share/agentv/branding/logo.txt"
check "About shows AgenTV's logo" \
  ssh_guest "cmp -s ~/.config/omarchy/branding/about.txt /usr/share/agentv/branding/logo.txt"
check "first boot left no passwordless sudo behind" ssh_sudo "! ls /etc/sudoers.d/ | grep -q nopasswd"

stop_vm
finish
