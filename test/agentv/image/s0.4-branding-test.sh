#!/bin/bash
#
# S0.4: the installer, the boot splash and the screensaver show AgenTV's logo,
# with "powered by omarchy" under it in the installer (ADR-021). That no file
# of Omarchy's is edited for it is the Check workflow's half.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# The installer: boot the ISO itself, answer nothing, and read the greeter,
# which draws /usr/share/omarchy/logo.txt with its "powered by omarchy" row.
# (The install dashboard shows Omarchy's mark while it works and the logo
# only on its finish screen, which an unattended install reboots past.)
installer_shows_logo() {
  qemu-img create -f qcow2 "$RUN_DIR/greeter.qcow2" 8G >/dev/null
  cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.greeter.fd"
  # shellcheck disable=SC2034 # start_vm reads it
  ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.greeter.fd"
  start_vm "$RUN_DIR/greeter.qcow2" "$RUN_DIR/greeter-serial.log" \
    -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
    -device ide-cd,drive=cdrom0,bootindex=2
  local found=1
  if wait_for_screen "powered by omarchy" 300; then
    capture_console "success-S0.4-installer"
    found=0
  fi
  stop_vm
  return $found
}
check "S0.4 the installer shows AgenTV's logo, powered by omarchy (OCR)" installer_shows_logo

# The ISO itself (ADR-027): the volume label a PC's boot menu lists, and the
# ISO's own boot menus.
volume_label_is_agentv() {
  local label
  label=$(dd if="$ISO" bs=1 skip=32808 count=32 2>/dev/null | tr -d ' ')
  printf '%s\n' "$label" >"$RUN_DIR/volume-label.txt"
  [[ $label == AGENTV_* ]]
}
boot_menus_say_agentv() {
  local grub syslinux
  grub=$(bsdtar -xOf "$ISO" boot/grub/grub.cfg 2>/dev/null) || return 1
  syslinux=$(bsdtar -xOf "$ISO" boot/syslinux/archiso_head.cfg 2>/dev/null) || return 1
  [[ $grub == *'menuentry "AgenTV ('* && $grub != *'menuentry "Omarchy'* && $syslinux == *"MENU TITLE AgenTV"* ]]
}
check "the ISO's volume label is AgenTV's" volume_label_is_agentv
check "the ISO's boot menus say AgenTV" boot_menus_say_agentv

log "Booting the installed system"
start_vm_from_base
wait_for_ssh 300 failure-S0.4-ssh-timeout || exit 1

# The splash: AgenTV's logo in the theme, that theme the default, and a boot
# image built after it, which is what the box actually shows at power on.
# First boot's own log has to say the branding step finished, too.
check "first boot's branding step finished" \
  ssh_sudo "grep -q 'Completed: .*/branding.sh' /var/log/agentv-firstboot.log"
check "S0.4 the boot splash is AgenTV's logo" \
  ssh_sudo "cmp -s /usr/share/plymouth/themes/omarchy/logo.png /usr/share/agentv/branding/plymouth-logo.png"
check "S0.4 the splash theme is the default" \
  ssh_sudo "[ \"\$(plymouth-set-default-theme)\" = omarchy ]"
check "S0.4 the boot image was rebuilt with the new splash" \
  ssh_sudo "[ -n \"\$(find /boot -name '*.efi' -newer /usr/share/plymouth/themes/omarchy/logo.png | head -n 1)\" ]"
check "S0.4 the screensaver is AgenTV's logo" \
  ssh_guest "cmp -s ~/.config/omarchy/branding/screensaver.txt /usr/share/agentv/branding/logo.txt"
check "About shows AgenTV's logo" \
  ssh_guest "cmp -s ~/.config/omarchy/branding/about.txt /usr/share/agentv/branding/logo.txt"
check "first boot left no passwordless sudo behind" ssh_sudo "! ls /etc/sudoers.d/ | grep -q nopasswd"

ssh_sudo "cat /var/log/agentv-firstboot.log" >"$RUN_DIR/agentv-firstboot.log" 2>&1 || true
ssh_guest "ls -la ~/.config/omarchy/branding/" >"$RUN_DIR/branding-files.txt" 2>&1 || true

stop_vm
finish
