#!/bin/bash
#
# T2.2: Settings → Power → restart to the boot menu (ADR-060). The TV opens
# Settings at Power, and keys choose the new row and answer its question,
# as the remote would. The box restarts and its boot menu shows and waits,
# with no key pressed. Enter on it boots the first entry, back to the TV.
# The request was for one boot only, so the next restart is quiet again.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# The boot loader's one-time request for its menu, as logind writes it.
ONE_SHOT=/sys/firmware/efi/efivars/LoaderConfigTimeoutOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f

# box_down <boot id> <seconds>: until SSH answers with another boot, or not
# at all.
box_down() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(ssh_guest "cat /proc/sys/kernel/random/boot_id" 2>/dev/null) != "$1" ]] && return 0
    sleep 0.5
  done
  return 1
}

start_vm_from_base
wait_for_ssh 300 failure-T2.2-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-T2.2-no-tv"; check "the TV session came up" false; stop_vm; finish; }

# Home rather than setup, where Settings is.
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

guest "busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanRebootToBootLoaderMenu" >"$RUN_DIR/can.txt" 2>&1 || true
check "logind says the owner can restart this box to its boot menu ($(cat "$RUN_DIR/can.txt"))" grep -qx 's "yes"' "$RUN_DIR/can.txt"

boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
guest "agentv screen settings power" >"$RUN_DIR/settings.json" 2>&1 || true
check "agentv screen settings opens Settings at Power" jq -e '.ok == true' "$RUN_DIR/settings.json"
sleep 2
# OK on Power goes into it, where Restart comes first; down twice is the
# boot menu's row, and OK on it asks.
for key in enter down down enter; do
  guest "agentv input key $key" >>"$RUN_DIR/input.log" 2>&1 || true
  sleep 1
done
sleep 1
capture_console "success-T2.2-question"
ocr_top "$RUN_DIR/success-T2.2-question.png" "$RUN_DIR/question.txt" || true
check "T2.2 Power asks first: restart to the boot menu? (OCR)" grep -qi "boot menu" "$RUN_DIR/question.txt"

# The answer: it goes at once, and asks the boot loader for its menu first.
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
check "the box went down within 20 s" box_down "$boot" 20

# No key is pressed: the menu shows by itself, and waits.
menu=0
if wait_for_screen "AgenTV" 120; then
  menu=1
  capture_console "success-T2.2-menu"
  ocr_screen >"$RUN_DIR/menu.txt" || true
fi
check "T2.2 restart to the boot menu comes back on AgenTV's boot menu (OCR)" test "$menu" = 1
if (( menu )); then
  check "the menu shows its help, so it's waiting for a choice" grep -qiE "enter +boot|arrows" "$RUN_DIR/menu.txt"
  sleep 20
  check "T2.2 the menu is still there 20 s later, with no countdown" wait_for_screen "AgenTV" 5
  capture_console "success-T2.2-menu-waits"
  press ret
  check "T2.2 Enter on the menu boots its first entry" wait_for_ssh 300 failure-T2.2-menu-ssh-timeout
  check "and that boot comes to home" wait_home 240
  check "the boot loader took the request, for that boot only" ssh_sudo "test ! -e $ONE_SHOT"
  guest "journalctl --user -b -1 --no-pager -o short-unix -u agentv-screen" >"$RUN_DIR/screen-before.log" 2>&1 || true
  check "the screen daemon restarted the box to its boot menu from Settings → Power" \
    grep -q "restarting the box to its boot menu from settings → power" "$RUN_DIR/screen-before.log"

  # The next restart is an ordinary one: quiet, with no menu and no key.
  boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
  ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
  box_down "$boot" 60 || true
  check "T2.2 the next restart is quiet again: the box comes back with no key pressed" wait_for_ssh 300 failure-T2.2-quiet-ssh-timeout
fi

stop_vm
finish
