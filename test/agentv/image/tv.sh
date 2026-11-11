#!/bin/bash
#
# Shared by AgenTV's TV session checks (ADR-031, stage 1). Source it after
# upstream's base-test.sh. It asks the installed box over SSH, as the person
# it logs in, what's on the TV: the screen daemon's status, the welcome
# page's /health and Hyprland's own view.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source test/agentv/image/tv.sh from a check; don't run it" >&2
  exit 1
fi

# A failed wait for SSH says why (ssh.sh).
source "$(dirname -- "${BASH_SOURCE[0]}")/ssh.sh"

# A command in a login shell on the box, with the owner's environment.
guest() {
  ssh_guest "bash -lc $(printf %q "$1") </dev/null"
}

screen_status() {
  guest "agentv screen status" 2>/dev/null || true
}

# A jq filter on the screen daemon's status, or nothing.
front() {
  jq -r "$1" <<<"$(screen_status)" 2>/dev/null || true
}

health() {
  ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/health" 2>/dev/null || true
}

# hyprctl against whichever Hyprland is running now, the TV session's or
# Omarchy's desktop's.
guest_hyprctl() {
  guest "HYPRLAND_INSTANCE_SIGNATURE=\$(ls -t \"\$XDG_RUNTIME_DIR/hypr\" | head -n 1) hyprctl $*"
}

# wait_tv <seconds> [<count>]: until the home screen is in front and the
# welcome page has been drawn more than <count> times. Prints the seconds it
# took.
wait_tv() {
  local started=$SECONDS count="${2:-0}"

  while (( SECONDS - started < $1 )); do
    if [[ $(front '.front.role // ""') == "home" ]] &&
      (( $(jq -r '.welcome_shown_count // 0' <<<"$(health)" 2>/dev/null || echo 0) > count )); then
      echo $(( SECONDS - started ))
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# wait_home <seconds>: until home is in front, for a box that's been set up,
# which shows no welcome page as it starts for wait_tv to wait for. Prints how
# many seconds it took.
wait_home() {
  local started=$SECONDS

  while (( SECONDS - started < $1 )); do
    if [[ $(front '.front.role // ""') == "home" ]]; then
      echo $(( SECONDS - started ))
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# wait_running <version> <seconds>: until AgenTV's daemon and screen daemon
# both run agentv <version> (/health and agentv screen status say which
# package each process started from) and the home screen is in front again.
# Prints the seconds it took.
wait_running() {
  local started=$SECONDS

  while (( SECONDS - started < $2 )); do
    if [[ $(jq -r '.running // ""' <<<"$(health)" 2>/dev/null) == "$1" &&
      $(front '"\(.running // "")/\(.front.role // "")"') == "$1/home" ]]; then
      echo $(( SECONDS - started ))
      return 0
    fi
    sleep 1
  done
  return 1
}

# The box needs a restart for its update: a new kernel, whose running
# kernel's modules are gone, or Omarchy's own flag. AgenTV's services then
# start again with the box rather than at the end of the update.
# shellcheck disable=SC2016 # expanded on the box
needs_restart() {
  guest '[[ ! -d /usr/lib/modules/$(uname -r) || -f ~/.local/state/omarchy/reboot-required ]]'
}

# wait_desktop <seconds>: until Omarchy's desktop is up, its bar on screen.
# Prints the seconds it took.
wait_desktop() {
  local started=$SECONDS

  while (( SECONDS - started < $1 )); do
    if guest_hyprctl "-j layers" 2>/dev/null | jq -e '[.. | objects | select(.namespace? == "omarchy-bar")] | length > 0' >/dev/null 2>&1; then
      echo $(( SECONDS - started ))
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# at_1080p <seconds>: the box as setup's box step leaves one that can't keep
# 4K smooth, such as the VM with virtio's GPU: the 4K test's result kept, and
# the TV at 1080p output, until Hyprland runs the screen at 1920 x 1080. For
# a check that times the TV or skips setup, which would otherwise leave QEMU's
# 4K screen drawn in software, slower than any box once setup has run.
# What the daemon said, and on a miss its display and the display lines of
# both daemons' logs, are in $RUN_DIR/at-1080p-*.
at_1080p() {
  local started=$SECONDS
  ssh_guest "curl -sS -X POST -H 'Content-Type: application/json' -d '{\"width\": 3840, \"height\": 2160, \"fps\": 10, \"slow\": 0.9}' http://127.0.0.1:3000/api/box/smooth" >"$RUN_DIR/at-1080p-smooth.json" 2>&1 || true
  while (( SECONDS - started < $1 )); do
    if [[ $(guest_hyprctl "-j monitors" 2>/dev/null | jq -r '.[0].width // 0' 2>/dev/null) == 1920 ]]; then
      return 0
    fi
    sleep 1
  done
  ssh_guest "curl -sS http://127.0.0.1:3000/api/display" >"$RUN_DIR/at-1080p-display.json" 2>&1 || true
  guest_hyprctl "-j monitors" >"$RUN_DIR/at-1080p-monitors.json" 2>&1 || true
  ssh_guest "journalctl -b --no-pager -u agentv-daemon | grep -i 'display\|4k'" >"$RUN_DIR/at-1080p-daemon.log" 2>&1 || true
  guest "journalctl --user -b --no-pager -u agentv-screen | grep -i 'display'" >"$RUN_DIR/at-1080p-screen.log" 2>&1 || true
  return 1
}

# What OCR reads on the welcome screen: setup's, which asks you to scan its
# code with your phone, the one before it, whose code to pair the phone sat
# beside its words, or the stage 0 placeholder an older release has, as
# before an update.
# shellcheck disable=SC2034 # the checks that source this use it
WELCOME_TEXT="scan the code with your phone|TV setup starts here|use a keyboard|1/6 connect"

# What OCR reads on home: the look's bar, whose links on home are apps, ask
# and settings (home itself sits in a block OCR misses), or an older
# release's grid, whose all apps tile says how many are installed.
# shellcheck disable=SC2034 # the checks that source this use it
HOME_TEXT="apps ask settings|installed|all apps"

# The welcome screen is on the TV, read with OCR, which reads it as scattered
# text too, since the QR code beside it turns a block reading to noise.
screen_shows_welcome() {
  capture_console "$1"
  ocr_finds "$1" "$WELCOME_TEXT" 15
}

# ocr_finds <name> <pattern> <seconds>: until OCR finds the pattern (grep -E,
# any case) on the screen. Each try reads one screenshot five ways: as a
# block of text, as ocr_screen does; as scattered text, which still reads a
# headline with a QR code beside it, where the block reading turns to noise
# at a VM's small screen; the right 62% as a block, larger, which leaves
# out a QR code on the left; the bottom 30% as a block, larger, where a
# small line such as the ambient screen's credit sits over a picture; and
# the top fifth, larger, where a toast sits over setup's moving pixels. A
# screen bigger than 1920 x 1080, such as QEMU's at 4K, is read at that size
# first, where the readings are tuned: tesseract misses text drawn that big.
# What it read last is in $RUN_DIR/<name>.txt, and the screenshot in
# $RUN_DIR/.ocr.ppm.
# The script's own output, for what a failed read says.
exec {OCR_LOG_FD}>&2

# One screenshot, read five ways (the whole screen twice, then its right,
# bottom and top parts enlarged), into the text file named second.
ocr_read() {
  local shot=$1 sized="$RUN_DIR/.ocr-sized.png" prepped="$RUN_DIR/.ocr.png" right="$RUN_DIR/.ocr-right.png" bottom="$RUN_DIR/.ocr-bottom.png" top="$RUN_DIR/.ocr-top.png"

  : >"$2"
  [[ -s $shot ]] || return 1
  magick "$shot" -resize '1920x1080>' "$sized" 2>/dev/null || return 1
  magick "$sized" -colorspace gray -negate -resize 150% "$prepped" 2>/dev/null || return 1
  {
    tesseract "$prepped" - --psm 6 2>/dev/null
    tesseract "$prepped" - --psm 11 2>/dev/null
    magick "$sized" -gravity east -crop 62%x100%+0+0 +repage -colorspace gray -negate -resize 200% "$right" 2>/dev/null &&
      tesseract "$right" - --psm 6 2>/dev/null
    magick "$sized" -gravity south -crop 100%x30%+0+0 +repage -colorspace gray -negate -resize 200% "$bottom" 2>/dev/null &&
      tesseract "$bottom" - --psm 6 2>/dev/null
    magick "$sized" -gravity north -crop 100%x20%+0+0 +repage -colorspace gray -negate -resize 200% "$top" 2>/dev/null &&
      tesseract "$top" - --psm 6 2>/dev/null
  } >"$2"
  return 0
}

# What a failed read saw, so the run's log says what was on the TV. check
# sends a function's own output nowhere, so it goes to the script's, kept
# open below.
ocr_missed() {
  {
    echo "$1 The first read:"
    grep -v '^[[:space:]]*$' "$2" 2>/dev/null | head -25
    echo "the last read:"
    grep -v '^[[:space:]]*$' "$3" 2>/dev/null | head -25
  } 1>&"$OCR_LOG_FD" 2>/dev/null || true
}

ocr_finds() {
  local started=$SECONDS reads=0 shot="$RUN_DIR/.ocr.ppm"

  while true; do
    rm -f "$shot"
    screendump "$shot"
    if ocr_read "$shot" "$RUN_DIR/$1.txt"; then
      grep -Eqi "$2" "$RUN_DIR/$1.txt" && return 0
    fi
    reads=$((reads + 1))
    (( reads > 1 )) || cp -f "$RUN_DIR/$1.txt" "$RUN_DIR/$1.first.txt" 2>/dev/null || true
    if (( SECONDS - started >= $3 )); then
      ocr_missed "ocr_finds: no \"$2\" in $3 s, in $reads reads." "$RUN_DIR/$1.first.txt" "$RUN_DIR/$1.txt"
      return 1
    fi
    sleep 1
  done
}

# The same, for a screen that's only up for a few seconds: ocr_finds_soon
# name pattern shots. One read takes about 10 s here, so a screen that comes
# and goes inside that is missed by reading as it goes. This takes the
# screenshots first, 2 s apart, and reads them afterwards.
ocr_finds_soon() {
  local i

  for (( i = 1; i <= $3; i++ )); do
    rm -f "$RUN_DIR/.ocr-soon-$i.ppm"
    screendump "$RUN_DIR/.ocr-soon-$i.ppm"
    (( i == $3 )) || sleep 2
  done
  for (( i = 1; i <= $3; i++ )); do
    ocr_read "$RUN_DIR/.ocr-soon-$i.ppm" "$RUN_DIR/$1.$i.txt" || continue
    if grep -Eqi "$2" "$RUN_DIR/$1.$i.txt"; then
      cp -f "$RUN_DIR/$1.$i.txt" "$RUN_DIR/$1.txt"
      return 0
    fi
  done
  ocr_missed "ocr_finds_soon: no \"$2\" in $3 screenshots 2 s apart." "$RUN_DIR/$1.1.txt" "$RUN_DIR/$1.$3.txt"
  return 1
}

# print_screen <screenshot>: prints it as a PNG in base64, in 16 greys, for
# a check that failed on what's on the screen. The job's log is the one
# thing of a run that can always be read back.
print_screen() {
  log "The screen, as a base64 PNG:"
  magick "$1" -colorspace gray -colors 16 png:- 2>/dev/null | base64 -w 120
  log "End of the screen"
}

# ocr_top <png> <txt>: reads the top fifth of a screenshot, where toasts and
# Hyprland's own notices are, larger than ocr_screen does, so small text
# comes through.
ocr_top() {
  magick "$1" -resize '1920x1080>' -gravity north -crop 100%x20%+0+0 +repage -colorspace gray -negate -resize 300% "$RUN_DIR/.top.png" 2>/dev/null &&
    tesseract "$RUN_DIR/.top.png" - --psm 6 >"$2" 2>/dev/null
}

# Omarchy's shell: its bar, notices, screensaver and lock. The bracket keeps
# pgrep from finding the shell that runs it, whose command line has the
# pattern in it too.
# shellcheck disable=SC2034 # the checks that source this use it
OMARCHY_SHELL='[/]usr/share/omarchy/shell'

# no_omarchy_shell <seconds>: within that long, no process of Omarchy's shell
# and none of its layers (omarchy-bar, omarchy-notifications and the rest) in
# the TV session (ADR-031). For after something that starts the shell, such
# as Omarchy's update, which restarts it in whatever session is running.
no_omarchy_shell() {
  local started=$SECONDS
  while (( SECONDS - started <= $1 )); do
    if ! ssh_guest "pgrep -f '$OMARCHY_SHELL'" >/dev/null 2>&1 &&
      [[ $(front '[.layers[]? | select(startswith("omarchy-"))] | length') == "0" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# A throwaway VM: sudo without a password, set up the way upstream's own
# test/upgrade-test does, as someone at the box would type theirs.
passwordless_sudo() {
  ssh_sudo "printf '%s\n' '$GUEST_USER ALL=(ALL:ALL) NOPASSWD: ALL' 'Defaults:$GUEST_USER !authenticate' >/etc/sudoers.d/zzz-agentv-test && chmod 440 /etc/sudoers.d/zzz-agentv-test"
}

# pair_phone [<name>] [<phone port's address>]: pairs a phone and prints the
# path of its key file on the box, for agentv-phone-call. The box shows a new
# code for it, as Settings → Phones does. Once a PIN is set that takes the
# PIN: a check that set one gives it in PHONE_PIN. With a PIN set and none
# given, it says so in the log and prints nothing.
pair_phone() {
  local env=""
  [[ -n ${2:-} ]] && env+="AGENTV_PHONE_URL=$2 "
  [[ -n ${PHONE_PIN:-} ]] && env+="AGENTV_PIN=$PHONE_PIN "
  if ! ssh_guest "${env}agentv-phone-call pair-new '${1:-image check}'" 2>"$RUN_DIR/pair-phone.log"; then
    log "No phone paired: $(tr '\n' ' ' <"$RUN_DIR/pair-phone.log")" >&2
  fi
}

# pin_off <pin>: takes the adult PIN off again, so a check that set one
# leaves the box as it found it. Each check runs on a disk of its own, so
# this is only for a box someone keeps and runs checks on by hand.
pin_off() {
  vm_running || return 0
  local grant
  grant=$(ssh_guest "curl -fsS --max-time 5 -H 'Content-Type: application/json' -d '{\"pin\":\"$1\"}' http://127.0.0.1:3000/api/pin/check" 2>/dev/null | jq -r '.grant // empty' 2>/dev/null || true)
  [[ -n $grant ]] || return 0
  ssh_guest "curl -fsS --max-time 5 -X DELETE -H 'X-AgenTV-Grant: $grant' http://127.0.0.1:3000/api/pin" >/dev/null 2>&1 || true
}

# For a check's EXIT trap: pin_off, then the checks' own cleanup, which
# still sees how the check ended.
pin_off_then_cleanup() {
  local status=$?
  pin_off "$1"
  (exit "$status")
  cleanup
}
