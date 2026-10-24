#!/bin/bash
#
# S1.7 (ADR-032): signing in to a service in the services' Chromium shows
# none of the browser's own prompts over the TV. A sign-in page in German,
# with an address too, is filled in through AgenTV's virtual keyboard, as
# the phone will, and sent. Then nothing of Chromium's shows: no Save
# password, Save address or card, Translate or notification bubble. The
# screen is read the way S1.1 reads notices, the top larger, and all of it.
# The page's own words are German, so English ones are Chromium's.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-s1.7-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-s1.7-no-tv"; check "the TV session came up" false; stop_vm; finish; }

# The pages, served on the box itself.
pages="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/pages"
ssh_guest "mkdir -p /tmp/agentv-sign-in"
for name in sign-in angemeldet; do
  ssh_guest "cat >/tmp/agentv-sign-in/$name.html" <"$pages/$name.html"
done
# Its log says what the form sent, so the test knows the keyboard filled it in.
ssh_guest "cd /tmp/agentv-sign-in && (nohup python3 -m http.server 8766 --bind 127.0.0.1 >requests.log 2>&1 &)"
page=http://127.0.0.1:8766/sign-in.html

# wait_front <role> <seconds>: until <role> is in front.
wait_front() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(front '.front.role // ""') == "$1" ]] && return 0
    sleep 0.5
  done
  return 1
}

# prompts <name>: what the screen shows now, read for Chromium's own words,
# the top fifth larger and then all of it, each as it is and inverted.
# Prints the words it found.
prompts() {
  local shot="$RUN_DIR/$1.png" words='save password|update password|password manager|save address|save card|autofill|translate|notification|allow|block|never'
  capture_console "$1"
  [[ -s $shot ]] || return 0
  {
    magick "$shot" -gravity north -crop 100%x20%+0+0 +repage -colorspace gray -resize 300% "$RUN_DIR/.top.png" 2>/dev/null &&
      tesseract "$RUN_DIR/.top.png" - --psm 6 2>/dev/null
    ocr_top "$shot" /dev/stdout
    magick "$shot" -colorspace gray -resize 150% "$RUN_DIR/.all.png" 2>/dev/null && tesseract "$RUN_DIR/.all.png" - --psm 6 2>/dev/null
    magick "$shot" -colorspace gray -negate -resize 150% "$RUN_DIR/.all.png" 2>/dev/null && tesseract "$RUN_DIR/.all.png" - --psm 6 2>/dev/null
  } >"$RUN_DIR/$1.txt" || true
  grep -Eoi "$words" "$RUN_DIR/$1.txt" | sort -u | tr '\n' ' ' || true
}

guest "agentv screen open $page" >>"$RUN_DIR/screen.log" 2>&1 || true
check "the sign-in page opens in the services' Chromium" wait_front web 60
sleep 3
capture_console "success-S1.7-sign-in"

# Typed the way the phone will: through the virtual keyboard, a Tab between
# fields, and the password from stdin, so it's on no command line.
printf 'zuschauer.berlin\tS17-kennwort-%s\tErika Mustermann\tHauptstrasse 1\t10115\tBerlin' "$RANDOM$RANDOM" |
  ssh_guest "bash -lc 'agentv input text -'" >>"$RUN_DIR/input.log" 2>&1 || true
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 6
found=$(prompts "success-S1.7-signed-in")
check "S1.7 the keyboard filled in the name and password, and the form was sent" \
  ssh_guest "grep -q 'benutzer=zuschauer.berlin&kennwort=S17-kennwort-[0-9]' /tmp/agentv-sign-in/requests.log"
check "S1.7 the sign-in went through (OCR)" grep -qi "angemeldet" "$RUN_DIR/success-S1.7-signed-in.txt"
check "S1.7 after signing in, no Save password, Save address or card, or Translate bubble (saw: ${found:-nothing})" test -z "$found"

# The signed-in page asks to send notifications when a key is pressed.
guest "agentv input key space" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 4
found=$(prompts "success-S1.7-notifications")
check "S1.7 a page that asks to send notifications gets no bubble (saw: ${found:-nothing})" test -z "$found"
check "the services' Chromium is still in front" wait_front web 5

# The settings themselves, as Chromium keeps them in the services' profile.
check "S1.7 the services' profile has password saving, autofill, translate and notifications off" \
  ssh_sudo "jq -e '.credentials_enable_service == false and .credentials_enable_autosignin == false and .autofill.profile_enabled == false and .autofill.credit_card_enabled == false and .translate.enabled == false and .profile.default_content_setting_values.notifications == 2' /var/lib/agentv/chromium/Default/Preferences >/dev/null"

guest "journalctl --user -b --no-pager -u agentv-screen -u agentv-input" >"$RUN_DIR/tv-session.log" 2>&1 || true
check "S1.7 nothing the keyboard typed is in the TV session's log" bash -c "! grep -q 'S17-kennwort' '$RUN_DIR/tv-session.log'"
stop_vm
finish
