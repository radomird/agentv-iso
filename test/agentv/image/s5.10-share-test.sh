#!/bin/bash
#
# S5.10: a link, a photo and a video sent from a paired phone each wait for
# Open on the TV and never interrupt playback (ADR-050). A phone pairs on the
# box's own address, as in S5.4's check, and sends each one as the web
# companion's Share page does.
#
# The photo, made here, opens full screen with its credit and becomes the
# background. The video comes while the stand-in app plays: it waits, and the
# TV asks only once Home has paused the app, then plays it in AgenTV's player
# until Back. A link no installed app declares opens in the share browser,
# Chromium on a profile of its own, never the services' one with the apps'
# sign-ins, and Back closes it.
#
# A box from before ADR-050 has nothing shared, and this check stands down.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

PAGES="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/pages"

# until_json <url path> <jq filter> <seconds>: until the filter on what the
# daemon answers there is true.
until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000$1" 2>/dev/null | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 1
}

# until_tv <jq filter> <seconds>: until the filter on what the phone hears
# of the TV is true.
until_tv() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(ssh_guest "curl -fsS --max-time 5 -H 'Authorization: Bearer $token' http://127.0.0.1:3001/api/phone/state" 2>/dev/null | jq -r ".tv | $1" 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 1
}

wait_front() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(front '.front.role // ""') == "$1" ]] && return 0
    sleep 0.5
  done
  return 1
}

# share <kind> <file on the box, or a link> [query]: as the phone sends it.
share() {
  if [[ $1 == "link" ]]; then
    ssh_guest "curl -fsS -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -d '{\"url\": \"$2\"}' http://127.0.0.1:3001/api/phone/share/link"
  else
    ssh_guest "curl -fsS -H 'Authorization: Bearer $token' -H 'Content-Type: application/octet-stream' --data-binary @$2 'http://127.0.0.1:3001/api/phone/share/$1${3:-}'"
  fi
}

key() {
  guest "agentv input key $1" >>"$RUN_DIR/input.log" 2>&1 || true
}

# asks <name> <what> <seconds>: until the TV's notice says the phone sent
# it. The notice is read on its own, from the top right of the screen, and
# its two lines as one, as what it says wraps after "sent a".
asks() {
  local shot="$RUN_DIR/.notice.ppm" w started=$SECONDS
  while (( SECONDS - started < $3 )); do
    rm -f "$shot"
    screendump "$shot"
    read -r w _ < <(magick identify -format '%w %h' "$shot" 2>/dev/null)
    if [[ -n ${w:-} ]] && magick "$shot" -crop "$(( w * 745 / 1920 ))x$(( w * 110 / 1920 ))+$(( w * 1125 / 1920 ))+$(( w * 60 / 1920 ))" +repage -colorspace gray -negate -resize 300% "$RUN_DIR/.notice.png" 2>/dev/null; then
      tesseract "$RUN_DIR/.notice.png" - --psm 6 2>/dev/null | tr '\n' ' ' >"$RUN_DIR/$1.txt"
      grep -Eqi "image check sent an? $2" "$RUN_DIR/$1.txt" && return 0
    fi
    sleep 1
  done
  return 1
}

start_vm_from_base
wait_for_ssh 300 failure-S5.10-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true

if [[ $(ssh_guest "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/shared" 2>/dev/null) != "200" ]]; then
  log "This agentv takes nothing shared from a phone, from before ADR-050; S5.10 waits for it"
  stop_vm
  finish
  exit 0
fi

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "setup skipped, home is in front${took:+ (after $took s)}" test -n "$took"
code=$(ssh_guest "curl -fsS -X POST http://127.0.0.1:3000/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
token=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\": \"$code\", \"name\": \"image check\"}' http://127.0.0.1:3001/api/phone/pair" 2>/dev/null | jq -r '.token // empty')
check "a phone pairs" test -n "$token"

# A photo: the TV asks, Open shows it, and it becomes the background.
magick -size 640x360 "xc:#336699" "$RUN_DIR/photo.jpg"
ssh_guest "cat >/tmp/share-photo.jpg" <"$RUN_DIR/photo.jpg"
share photo /tmp/share-photo.jpg "?credit=photo%20by%20the%20image%20check" >"$RUN_DIR/photo.json" 2>&1 || true
check "S5.10 the phone shares a photo" jq -e '.share.kind == "photo"' "$RUN_DIR/photo.json"
check "S5.10 the TV asks first, saying who sent what (OCR)" asks success-S5.10-notice "photo: photo by the image check" 20
capture_console "success-S5.10-notice"
key enter
# Its own page, not the notice, which has the credit too.
check "S5.10 Open shows the photo full screen, with its credit (OCR)" ocr_finds success-S5.10-photo "photo by the image check.*make it the background" 20
capture_console "success-S5.10-photo"
key enter
# shellcheck disable=SC2016
check "S5.10 and makes it the background" until_json /api/backgrounds '.current as $c | [.items[] | select(.id == $c and .credit.text == "photo by the image check")] | length == 1' 15
key back
check "Back closes it" until_tv '.front == "home" and (.playing | not)' 15

# A video while the stand-in app plays: it waits, and never interrupts it.
ssh_guest "mkdir -p /tmp/agentv-page && cat >/tmp/agentv-page/index.html" <"$PAGES/media.html"
ssh_guest "cd /tmp/agentv-page && (nohup python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &)"
guest "agentv screen open http://127.0.0.1:8765/" >>"$RUN_DIR/screen.log" 2>&1 || true
check "the stand-in app opens in front" wait_front web 60
key enter
check "and plays" until_tv '.front == "app" and .playing' 20
ssh_guest "cat >/tmp/share-clip.webm" <"$PAGES/clip.webm"
share video /tmp/share-clip.webm "?name=clip.webm" >"$RUN_DIR/video.json" 2>&1 || true
check "S5.10 the phone shares a video, and hears it waits while something plays" jq -e '.share.kind == "video" and .waits' "$RUN_DIR/video.json"
sleep 5
check "S5.10 it never interrupts playback: the app stays in front, playing" until_tv '.front == "app" and .playing' 5
check "S5.10 and the TV doesn't ask over it" until_json /api/shared '.ask == null' 5
# Home pauses the app, and with nothing playing the TV asks.
guest "agentv screen home" >>"$RUN_DIR/screen.log" 2>&1 || true
check "S5.10 once nothing plays, the TV asks about the video (OCR)" asks success-S5.10-video-notice "video: clip.webm" 30
key enter
check "S5.10 Open plays it in AgenTV's player" until_tv '.front == "home" and .playing' 20
capture_console "success-S5.10-video"
key back
check "Back closes the player" until_tv '(.playing | not)' 15

# A link no app declares: the share browser, on its own profile.
share link "http://127.0.0.1:8765/?shared=1" >"$RUN_DIR/link.json" 2>&1 || true
check "S5.10 the phone shares a link" jq -e '.share.kind == "link"' "$RUN_DIR/link.json"
check "S5.10 the TV asks about the link (OCR)" asks success-S5.10-link-notice "link" 30
key enter
check "S5.10 Open opens it in the share browser" wait_front share 30
guest "pgrep -af -- '--user-data-dir=[^ ]*chromium-share'" >"$RUN_DIR/share-browser.txt" 2>&1 || true
check "S5.10 on a profile of its own, not the services' one with the apps' sign-ins" grep -q -- "chromium-share" "$RUN_DIR/share-browser.txt"
check "S5.10 with the page it was sent" grep -q -- "shared=1" "$RUN_DIR/share-browser.txt"
capture_console "success-S5.10-link"
key back
check "Back closes it, and home's in front" wait_front home 20

guest "journalctl --user -b --no-pager -u agentv-screen | grep -i share | tail -n 30" >"$RUN_DIR/screen-share.log" 2>&1 || true
stop_vm
finish
