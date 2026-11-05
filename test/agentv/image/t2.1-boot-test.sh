#!/bin/bash
#
# T2.1: straight to the TV (ADR-060). From power on to home, the TV shows the
# firmware's own screen, then AgenTV's splash until home is drawn: no boot
# menu, no text and no black screen on the way. A recorder reads the screen
# about ten times a second from the moment the VM is switched on, and OCR
# reads every frame that changed (frames.py). Then a key in the boot
# loader's quiet second shows AgenTV's boot menu, which waits, and Enter on
# it boots the first entry, back to the TV.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# power_on <name> [<qemu option>...]: switches this run's own disk on again.
# start_vm_from_base would make the disk anew and lose what an earlier boot
# set, such as the switch below.
power_on() {
  local name=$1
  shift
  start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/serial-$name.log" "$@"
}

# until_handover <serial log> <seconds>: until the firmware starts the boot
# loader, which OVMF writes to the serial port.
until_handover() {
  local started=$SECONDS
  until grep -qa "BdsDxe: starting" "$1" 2>/dev/null; do
    (( SECONDS - started < $2 )) || return 1
    sleep 0.05
  done
}

log "Booting the installed system once, to get it ready"
start_vm_from_base
wait_for_ssh 300 failure-T2.1-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-T2.1-no-tv"; check "the TV session came up" false; stop_vm; finish; }

# The switch for booting straight to the TV, on, while its default is off.
if guest "agentv feature on boot" >"$RUN_DIR/feature.log" 2>&1; then
  log "agentv feature on boot: $(tr '\n' ' ' <"$RUN_DIR/feature.log")"
else
  log "No switch for it on this box: $(tr '\n' ' ' <"$RUN_DIR/feature.log")"
fi

# The boot loader as Omarchy 4.5 sets it: one quiet second (ADR-060).
ssh_sudo "cat /boot/limine.conf" >"$RUN_DIR/limine.conf.txt" 2>&1 || true
ssh_guest "pacman -Q limine" >"$RUN_DIR/limine-version.txt" 2>&1 || true
log "$(cat "$RUN_DIR/limine-version.txt"), $(grep -E '^(timeout|quiet):' "$RUN_DIR/limine.conf.txt" | paste -sd ' ')"
check "T2.1 the boot loader waits one quiet second (timeout: 1, quiet: yes)" \
  bash -c "grep -qx 'timeout: 1' '$RUN_DIR/limine.conf.txt' && grep -qx 'quiet: yes' '$RUN_DIR/limine.conf.txt'"

# The splash's own background colour, as omarchy plymouth set wrote it.
background=$(ssh_guest "sed -n 's/^Window.SetBackgroundTopColor(\(.*\));/\1/p' /usr/share/plymouth/themes/omarchy/omarchy.script" 2>/dev/null |
  awk -F', *' 'NF == 3 { printf "#%02x%02x%02x", $1 * 255 + 0.5, $2 * 255 + 0.5, $3 * 255 + 0.5 }')
background=${background:-#1a1b26}
log "The splash's background: $background"
stop_vm

log "Switching it on, with the screen recorded"
rm -rf "$RUN_DIR/frames" "$RUN_DIR/frames.stop"
# Started paused, so the recorder has the first frame before anything runs.
power_on recorded -S -qmp "unix:$RUN_DIR/frames.qmp,server,nowait"
python3 "$HERE/frames.py" record --qmp "$RUN_DIR/frames.qmp" --out "$RUN_DIR/frames" \
  --serial "$RUN_DIR/serial-recorded.log" --stop "$RUN_DIR/frames.stop" --max 480 >"$RUN_DIR/frames-record.log" 2>&1 &
recorder=$!
up=0
if wait_for_ssh 300 failure-T2.1-recorded-ssh-timeout && wait_tv 240 >"$RUN_DIR/tv-seconds.txt"; then
  up=1
  # A few seconds of home, so the recording has it settled.
  sleep 5
fi
touch "$RUN_DIR/frames.stop"
wait "$recorder" || true
cat "$RUN_DIR/frames-record.log"
check "the TV came up after the recorded boot" test "$up" = 1

log "What the TV showed, frame by frame"
python3 "$HERE/frames.py" analyse --out "$RUN_DIR/frames" --background "$background" --home "$WELCOME_TEXT|installed" |
  tee "$RUN_DIR/timeline.txt" || true
verdict() {
  jq -r "$1" "$RUN_DIR/frames/timeline.json" 2>/dev/null
}
jq '.verdict' "$RUN_DIR/frames/timeline.json" 2>/dev/null || true
check "the recorder saw the firmware hand over to the boot loader" test "$(verdict .verdict.handover)" = true
check "T2.1 no boot menu on the screen from power on to home (OCR every frame)" test "$(verdict '.verdict.menu | length')" = 0
check "T2.1 no text on the screen from the boot loader to home (OCR every frame)" test "$(verdict '.verdict.text | length')" = 0
check "T2.1 AgenTV's splash shows on the way" test "$(verdict .verdict.splash)" = true
check "T2.1 the splash stays until home is drawn, with no black screen or anything else between them" \
  test "$(verdict '.verdict.gaps | length')" = 0
check "home is on the recording" test "$(verdict .verdict.home)" = true
stop_vm

log "Switching it on again, with a key pressed in the boot loader's quiet second"
power_on key
if until_handover "$RUN_DIR/serial-key.log" 120; then
  # A key every tenth of a second for three seconds covers the quiet
  # second, which starts as the firmware hands over. The menu does nothing
  # with x.
  for (( i = 0; i < 30; i++ )); do
    press x
    sleep 0.1
  done
fi
menu=0
if wait_for_screen "AgenTV" 30; then
  menu=1
  capture_console "success-T2.1-menu"
  ocr_screen >"$RUN_DIR/menu.txt" || true
fi
check "T2.1 a key in the boot loader's first second shows AgenTV's boot menu (OCR)" test "$menu" = 1
if (( menu )); then
  check "the menu has AgenTV's snapshots on it" grep -qi "snapshot" "$RUN_DIR/menu.txt"
  # A key stops the countdown, so the menu waits for a choice.
  sleep 10
  check "the menu is still there 10 s later" wait_for_screen "AgenTV" 5
  capture_console "success-T2.1-menu-waits"
  press ret
  check "Enter on the menu boots its first entry" wait_for_ssh 300 failure-T2.1-menu-ssh-timeout
  check "and that boot comes to the TV" wait_tv 240
fi

stop_vm
finish
