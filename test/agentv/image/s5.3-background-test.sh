#!/bin/bash
#
# S5.3: a photo shared from the phone becomes the background, with its credit
# (ADR-012). A phone paired on the box's own address sends a photo, as the
# web companion's Share → TV does, with a credit line. The daemon keeps it in
# /var/lib/agentv/backgrounds and makes it the background: home has it behind
# the tiles, and the ambient screen shows it with the credit, which OCR reads.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

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

# brightness <name>: the whole screen's mean brightness, 0 to 1.
brightness() {
  local shot="$RUN_DIR/$1.ppm"
  screendump "$shot"
  magick "$shot" -colorspace gray -format '%[fx:mean]' info: 2>/dev/null || echo 0
}

start_vm_from_base
wait_for_ssh 300 failure-S5.3-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "setup skipped, home is in front${took:+ (after $took s)}" test -n "$took"
# Since ADR-048 a new box shows the theme's own backgrounds; the pixel field
# first, so home starts in its plain colours.
ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"source\": \"field\"}' http://127.0.0.1:3000/api/backgrounds" >"$RUN_DIR/field.json" 2>&1 || true
check "the TV is on its pixel field, with no photo" until_json /api/backgrounds '.source == "field" and (.items | length) == 0' 30
sleep 2
before=$(brightness home-before)

# A phone on the box's own address pairs, as from the TV's code.
code=$(ssh_guest "curl -fsS -X POST http://127.0.0.1:3000/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
token=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\": \"$code\", \"name\": \"image check\"}' http://127.0.0.1:3001/api/phone/pair" 2>/dev/null | jq -r '.token // empty')
check "a phone pairs" test -n "$token"

# The photo, made here, and sent from the phone with its credit.
magick -size 1920x1080 gradient:'#1f4e79-#e8a33d' -quality 90 jpg:- 2>/dev/null | ssh_guest "cat >/tmp/s5.3.jpg"
ssh_guest "curl -fsS -H 'Authorization: Bearer $token' -H 'Content-Type: image/jpeg' --data-binary @/tmp/s5.3.jpg 'http://127.0.0.1:3001/api/phone/background?credit=photo%20by%20the%20image%20check'" >"$RUN_DIR/sent.json" 2>&1 || true
id=$(jq -r '.background.id // empty' "$RUN_DIR/sent.json" 2>/dev/null)
check "S5.3 the box takes the photo from the phone, with its credit" jq -e '.ok and .background.credit.text == "photo by the image check"' "$RUN_DIR/sent.json"
check "S5.3 it's the background now" until_json /api/backgrounds ".source == \"photos\" and .current == \"$id\"" 10
check "it's kept in /var/lib/agentv/backgrounds" ssh_sudo "test -f /var/lib/agentv/backgrounds/$id.jpg"
check "which the daemon's own user has, not the owner's account" \
  test "$(ssh_sudo "stat -L -c %U /var/lib/agentv/backgrounds/$id.jpg")" != "$GUEST_USER"
sleep 3
after=$(brightness home-after)
capture_console "success-S5.3-home"
check "S5.3 home has it behind the tiles (brightness $before, then $after)" awk -v b="$before" -v a="$after" 'BEGIN { exit !(a > b + 0.04) }'

# The ambient screen shows it, with its credit.
guest "agentv screen ambient" >"$RUN_DIR/ambient.log" 2>&1 || true
check "S5.3 the ambient screen shows the photo with its credit (OCR)" ocr_finds success-S5.3-ambient "photo by the image check" 30
capture_console "success-S5.3-ambient"
guest "agentv screen home" >>"$RUN_DIR/ambient.log" 2>&1 || true

stop_vm
finish
