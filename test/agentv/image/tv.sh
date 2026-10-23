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

# A throwaway VM: sudo without a password, set up the way upstream's own
# test/upgrade-test does, as someone at the box would type theirs.
passwordless_sudo() {
  ssh_sudo "printf '%s\n' '$GUEST_USER ALL=(ALL:ALL) NOPASSWD: ALL' 'Defaults:$GUEST_USER !authenticate' >/etc/sudoers.d/zzz-agentv-test && chmod 440 /etc/sudoers.d/zzz-agentv-test"
}
