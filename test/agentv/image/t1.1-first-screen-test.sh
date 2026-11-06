#!/bin/bash
#
# T1.1: the USB stick boots to AgenTV's own first screen, step 1 of 12, which
# asks only which disk. One press of Enter installs on the disk it
# highlights, with no question of Omarchy's on the screen from the boot to
# the restart (OCR). The box restarts by itself and lands in TV setup's first
# screen. On it, the box is called agentv, the account is agentv, the disk
# isn't encrypted, and the box knows nobody knows the account's password.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/first-screen.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# The account the first screen makes. Its password is one nobody knows, so
# the harness logs in with its key, and the VM stops from QEMU.
# shellcheck disable=SC2034 # ssh_guest reads it
GUEST_USER=agentv

log "Booting the USB stick onto a blank disk"
boot_stick t1.1
wait_for_live_root_ssh 300 || { stop_vm; finish; }

check "T1.1 the USB stick boots to AgenTV's first screen, step 1 of 12 (OCR)" wait_for_screen "of 12" 300
capture_console "success-T1.1-first-screen"
ocr_screen >"$RUN_DIR/first-screen.txt"
cat "$RUN_DIR/first-screen.txt"

# first_screen_says <pattern>: what OCR read finds it (grep -E, any case).
# The screen stays put, so OCR reads it again, up to three more times, and
# each reading goes in first-screen.txt, where the check below for
# Omarchy's questions reads them all too.
first_screen_says() {
  local tries=0
  until grep -qiE "$1" "$RUN_DIR/first-screen.txt"; do
    (( tries++ < 3 )) || return 1
    sleep 2
    { echo; ocr_screen; } >>"$RUN_DIR/first-screen.txt"
  done
}

check "it asks which disk to install on" first_screen_says "install agentv on"
# OCR misreads this font next to the QR code beside these lines: "uill",
# "oun", "ouwn", "bhe erased", "evergthing", "ui w0 eraser", and the
# apostrophe as two ("omarchy’'s"). So each line is matched by the words it
# reads steadily, at the start of the line or close to its end, and read
# again if it misses.
check "and says everything on it will be erased" first_screen_says "ever.thing on it|on it .{0,12}eras"
check "and that Ctrl+C gives Omarchy's own installer" first_screen_says "ctrl.c omarchy.{1,6}s .*installer"
# shellcheck disable=SC2016 # the single quotes hold the inner bash's own
check "T1.1 no question of Omarchy's on it (OCR)" \
  bash -c '! grep -qiE "$1|password|language|email" "$2"' _ "$OMARCHY_QUESTIONS" "$RUN_DIR/first-screen.txt"

give_key
log "Pressing Enter, once"
press ret
installed=0
wait_for_box t1.1 && installed=1
check "T1.1 one press of Enter installed it, and the box restarted by itself" test "$installed" = 1
(( installed )) || { stop_vm; finish; }
if [[ -n $QUESTIONS_SEEN ]]; then
  printf '%s\n' "$QUESTIONS_SEEN" >"$RUN_DIR/questions.txt"
  cat "$RUN_DIR/questions.txt"
fi
check "T1.1 no question of Omarchy's on the screen while it installed (OCR every 10 s)" test -z "$QUESTIONS_SEEN"

check "the box is called agentv" test "$(ssh_guest hostname 2>/dev/null)" = agentv
check "its account is agentv, with sudo" ssh_guest "id -nG | grep -qw wheel"
check "the disk isn't encrypted" ssh_guest "! lsblk -no TYPE | grep -qx crypt"
check "the box knows nobody knows the account's password" \
  ssh_guest "jq -e '.name == \"agentv\" and .passwordKnown == false' /var/lib/agentv/account.json"
check "T1.1 TV setup's first screen is on the TV (daemon /health)" tv_setup_on_screen
capture_console "success-T1.1-tv-setup"

stop_vm
finish
