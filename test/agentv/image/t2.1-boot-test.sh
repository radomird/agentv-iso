#!/bin/bash
#
# T2.1: straight to the TV (ADR-060). From power on to home, the TV shows the
# firmware's own screen, then AgenTV's splash until home is drawn: no boot
# menu, no text and no black or white screen on the way. A recorder reads
# the screen about ten times a second from the moment the VM is switched on,
# and OCR reads every frame that changed (frames.py). That's an ordinary
# boot, then a first boot again, whose work, such as rebuilding the boot
# image, happens behind the splash too. Then a key in the boot loader's
# quiet second shows AgenTV's boot menu, which waits, and Enter on it boots
# the first entry, back to the TV.
#
# It takes about eight minutes: three boots, two of them read frame by
# frame, and a first boot's rebuild of the boot image.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Home, or setup's welcome page on a box not set up yet, as OCR reads it.
# "scan the code" is the welcome page's line OCR reads best, over its
# moving background.
HOME_TEXT="$WELCOME_TEXT|scan the code|phone waiting|installed"

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
# Only an edge box turns a switch on.
ssh_sudo "agentv channel edge" >"$RUN_DIR/channel.log" 2>&1 || true
guest "agentv feature on boot" >"$RUN_DIR/feature.log" 2>&1 || true
log "agentv feature on boot: $(tr '\n' ' ' <"$RUN_DIR/feature.log")"
check "the boot switch is on" guest "agentv feature list | grep -qE '^boot +on\$'"

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

# record <name> <what>: switches the box on with the screen recorded until
# home is up, then reads the recording and checks what the TV showed.
record() {
  local name=$1 what=$2 recorder up=0 frames="$RUN_DIR/frames-$1"
  log "Switching it on, with the screen recorded: $what"
  rm -rf "$frames" "$RUN_DIR/frames.stop"
  # Started paused, so the recorder has the first frame before anything runs.
  power_on "$name" -S -qmp "unix:$RUN_DIR/frames.qmp,server,nowait"
  python3 "$HERE/frames.py" record --qmp "$RUN_DIR/frames.qmp" --out "$frames" \
    --serial "$RUN_DIR/serial-$name.log" --stop "$RUN_DIR/frames.stop" --max 600 >"$RUN_DIR/frames-$name.log" 2>&1 &
  recorder=$!
  if wait_for_ssh 420 "failure-T2.1-$name-ssh-timeout" && wait_tv 300 >"$RUN_DIR/tv-seconds-$name.txt"; then
    up=1
    # Home is up, and the splash goes once its page has drawn: until OCR
    # reads home on the screen, for 20 s at most, then a few seconds of it
    # settled.
    for (( i = 0; i < 20; i++ )); do
      ocr_screen_once 2>/dev/null | grep -Eqi "$HOME_TEXT" && break
      sleep 1
    done
    sleep 3
  fi
  touch "$RUN_DIR/frames.stop"
  wait "$recorder" || true
  cat "$RUN_DIR/frames-$name.log"
  check "the TV came up after the recorded $what" test "$up" = 1

  log "What the TV showed, frame by frame: $what"
  python3 "$HERE/frames.py" analyse --out "$frames" --background "$background" --home "$HOME_TEXT" |
    tee "$RUN_DIR/timeline-$name.txt" || true
  verdict() {
    jq -r "$1" "$frames/timeline.json" 2>/dev/null
  }
  jq '.verdict' "$frames/timeline.json" 2>/dev/null || true
  check "the recorder saw the firmware hand over to the boot loader ($what)" test "$(verdict .verdict.handover)" = true
  check "T2.1 no boot menu on the screen from power on to home, $what (OCR every frame)" test "$(verdict '.verdict.menu | length')" = 0
  check "T2.1 no text on the screen from the boot loader to home, $what (OCR every frame)" test "$(verdict '.verdict.text | length')" = 0
  check "T2.1 AgenTV's splash shows on the way, $what" test "$(verdict .verdict.splash)" = true
  check "T2.1 the splash stays until home is drawn, with no black or white screen between them, $what" \
    test "$(verdict '.verdict.gaps | length')" = 0
  check "home is on the recording, $what" test "$(verdict .verdict.home)" = true
  log "The splash's background alone, before the TV session's splash drew: $(verdict .verdict.background_seconds) s"
  # What the boot and the screen daemon said about the splash, with when,
  # in seconds since the kernel started.
  # journalctl takes a tag and a unit together as both, so they're asked
  # for one after the other.
  ssh_sudo "{ journalctl -b --no-pager -o short-monotonic -t agentv-boot-splash; journalctl -b --no-pager -o short-monotonic -u plymouth-start -u plymouth-quit -u plymouth-quit-wait -u agentv-boot-splash-release -u sddm; } | sort -u" \
    >"$RUN_DIR/splash-$name.log" 2>&1 || true
  guest "journalctl --user -b --no-pager -o short-monotonic -u agentv-screen" >"$RUN_DIR/screen-$name.log" 2>&1 || true
  grep -hE "agentv-boot-splash|plymouth|Plymouth|Display Manager|in front: home|splash goes" "$RUN_DIR/splash-$name.log" "$RUN_DIR/screen-$name.log" | cut -c1-200 || true
}

record recorded "an ordinary boot"
check "T2.1 the kernel keeps the splash up with a serial console (plymouth.ignore-serial-consoles)" \
  ssh_guest "grep -qw plymouth.ignore-serial-consoles /proc/cmdline"

# First boot again: its work runs before the login manager, behind the
# splash, rebuilding the boot image among the rest.
ssh_sudo "rm -f /var/lib/agentv/firstboot.done" >/dev/null 2>&1 || true
stop_vm
record firstboot "a first boot"
check "first boot ran again, behind the splash" ssh_sudo "test -f /var/lib/agentv/firstboot.done"
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
  # AgenTV's entry, with the kernel under it (and the snapshots, once an
  # update has made one).
  check "the menu has AgenTV's entry on it" grep -qiE "omarchy|linux" "$RUN_DIR/menu.txt"
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
