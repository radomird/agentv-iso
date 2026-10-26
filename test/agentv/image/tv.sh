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

# The welcome page's text is on the screen, read with OCR.
screen_shows_welcome() {
  ocr_screen >"$RUN_DIR/$1.txt" 2>/dev/null || true
  capture_console "$1"
  grep -q "TV setup starts here" "$RUN_DIR/$1.txt"
}

# ocr_finds <name> <pattern> <seconds>: until OCR finds the pattern (grep -E,
# any case) on the screen. Each try reads one screenshot three ways: as a
# block of text, as ocr_screen does; as scattered text, which still reads a
# headline with a QR code beside it, where the block reading turns to noise
# at a VM's small screen; and the right 62% as a block, larger, which leaves
# out a QR code on the left. What it read last is in $RUN_DIR/<name>.txt,
# and the screenshot in $RUN_DIR/.ocr.ppm.
ocr_finds() {
  local started=$SECONDS shot="$RUN_DIR/.ocr.ppm" prepped="$RUN_DIR/.ocr.png" right="$RUN_DIR/.ocr-right.png"

  while true; do
    : >"$RUN_DIR/$1.txt"
    rm -f "$shot"
    screendump "$shot"
    if [[ -s $shot ]] && magick "$shot" -colorspace gray -negate -resize 150% "$prepped" 2>/dev/null; then
      {
        tesseract "$prepped" - --psm 6 2>/dev/null
        tesseract "$prepped" - --psm 11 2>/dev/null
        magick "$shot" -gravity east -crop 62%x100%+0+0 +repage -colorspace gray -negate -resize 200% "$right" 2>/dev/null &&
          tesseract "$right" - --psm 6 2>/dev/null
      } >"$RUN_DIR/$1.txt"
      grep -Eqi "$2" "$RUN_DIR/$1.txt" && return 0
    fi
    (( SECONDS - started < $3 )) || return 1
    sleep 1
  done
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
  magick "$1" -gravity north -crop 100%x20%+0+0 +repage -colorspace gray -negate -resize 300% "$RUN_DIR/.top.png" 2>/dev/null &&
    tesseract "$RUN_DIR/.top.png" - --psm 6 >"$2" 2>/dev/null
}

# Omarchy's shell: its bar, notices, screensaver and lock. The bracket keeps
# pgrep from finding the shell that runs it, whose command line has the
# pattern in it too.
# shellcheck disable=SC2034 # the checks that source this use it
OMARCHY_SHELL='[/]usr/share/omarchy/shell'

# A throwaway VM: sudo without a password, set up the way upstream's own
# test/upgrade-test does, as someone at the box would type theirs.
passwordless_sudo() {
  ssh_sudo "printf '%s\n' '$GUEST_USER ALL=(ALL:ALL) NOPASSWD: ALL' 'Defaults:$GUEST_USER !authenticate' >/etc/sudoers.d/zzz-agentv-test && chmod 440 /etc/sudoers.d/zzz-agentv-test"
}
