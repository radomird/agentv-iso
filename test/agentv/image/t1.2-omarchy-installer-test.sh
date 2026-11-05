#!/bin/bash
#
# T1.2: Ctrl+C on AgenTV's first screen gives Omarchy's own installer, every
# question included, and an install through it lands in TV setup's first
# screen, the way an install with Enter does. The answers here are the ones
# a person would give: the account the harness always uses, its password,
# and Enter for everything else (AgenTV's box name, no encryption).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/first-screen.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

log "Booting the USB stick onto a blank disk"
boot_stick t1.2
wait_for_live_root_ssh 300 || { stop_vm; finish; }

check "AgenTV's first screen comes up (OCR)" wait_for_screen "of 12" 300
capture_console "success-T1.2-first-screen"
press ctrl-c
# Omarchy's greeter, under AgenTV's logo and tagline. Its "Press Return"
# line is too dim for OCR, so the tagline it shows is what's looked for.
check "T1.2 Ctrl+C on it gives Omarchy's own installer (OCR)" wait_for_screen "agentic TV" 60
capture_console "success-T1.2-omarchy-greeter"
give_key
press ret

# Omarchy's questions, answered as they come. The summary repeats every
# field's name, so it's looked for first, and each question is answered
# once. OCR reads this font's w as u at times ("overuriting"), so the
# overwrite confirm is matched without its w.
drive_omarchy_installer() {
  local waited=0 text step
  local -A answered=()
  while (( waited < 900 )); do
    text=$(ocr_screen)
    step=""
    if grep -qi "look right" <<<"$text"; then
      step=summary; [[ -v answered[$step] ]] || { capture_console "success-T1.2-summary"; press ret; }
    elif grep -qi "Confirm over" <<<"$text"; then
      step=overwrite; [[ -v answered[$step] ]] || { capture_console "success-T1.2-overwrite"; press ret; }
    elif grep -qi "Select install disk" <<<"$text"; then
      step=disk; [[ -v answered[$step] ]] || { capture_console "success-T1.2-disk"; press ret; }
    elif grep -qi "keyboard layout" <<<"$text"; then
      step=keyboard; [[ -v answered[$step] ]] || { capture_console "success-T1.2-keyboard"; press ret; }
    elif grep -qi "Username" <<<"$text"; then
      step=username; [[ -v answered[$step] ]] || { type_text "$GUEST_USER"; press ret; }
    elif grep -qi "Conf *irm" <<<"$text"; then
      step=confirm; [[ -v answered[$step] ]] || { type_text "$GUEST_PASSWORD"; press ret; }
    elif grep -qi "Password" <<<"$text"; then
      step=password; [[ -v answered[$step] ]] || { type_text "$GUEST_PASSWORD"; press ret; }
    elif grep -qi "Hostname" <<<"$text"; then
      step=hostname; [[ -v answered[$step] ]] || { capture_console "success-T1.2-hostname"; press ret; }
    elif grep -qi "Timezone" <<<"$text"; then
      step=timezone; [[ -v answered[$step] ]] || press ret
    elif grep -qi "Language" <<<"$text"; then
      step=language; [[ -v answered[$step] ]] || press ret
    elif grep -qiE "Installing|[0-9]+%" <<<"$text" && [[ -v answered[overwrite] ]]; then
      capture_console "success-T1.2-installing"
      return 0
    fi
    [[ -n $step ]] && answered[$step]=1
    vm_running || return 1
    sleep 3
    (( waited += 3 ))
  done
  capture_console "failure-T1.2-questions-timeout"
  return 1
}
check "T1.2 Omarchy's installer asks its questions, and takes the answers" drive_omarchy_installer

# Omarchy's own finish screen asks to reboot, as it always does.
installed=0
wait_for_unattended_install t1.2 "$STICK_SERIAL" && installed=1
check "T1.2 the install from it finished, and the box restarted" test "$installed" = 1
(( installed )) || { keep_install_logs; stop_vm; finish; }

check "the account is the one typed in" ssh_guest "test \"\$(id -un)\" = $GUEST_USER"
check "Enter at the box's name gave it AgenTV's" test "$(ssh_guest hostname 2>/dev/null)" = agentv
check "the disk isn't encrypted, Enter at the overwrite" ssh_guest "! lsblk -no TYPE | grep -qx crypt"
check "AgenTV's first screen handed nothing over" ssh_guest "! test -e /var/lib/agentv/account.json"
check "T1.2 TV setup's first screen is on the TV (daemon /health)" tv_setup_on_screen
capture_console "success-T1.2-tv-setup"

stop_vm
finish
