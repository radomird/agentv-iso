#!/bin/bash
#
# S5.4: the setup soundtrack plays from the welcome screen, with its player,
# and muting it from the phone stops it (ADR-014). The check records a few
# seconds of what the box's own output plays, from PipeWire's monitor of it,
# and measures how loud it is: something while the soundtrack plays, next to
# nothing once a phone on the box's own address has muted it. The equaliser
# moving with the music is layer 4's: a VM's screen can't show it.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000$1" 2>/dev/null | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 1
}

# loudness <name>: three seconds of what the box plays, from the default
# output's monitor, as the root mean square of its samples, 0 to 1.
loudness() {
  # timeout ends the recording, so its exit says nothing; pw-record is
  # PipeWire's own, for a box without parec.
  guest "rm -f /tmp/$1.raw; if command -v parec >/dev/null; then timeout 3 parec -d @DEFAULT_MONITOR@ --format=s16le --channels=1 --rate=8000 --raw >/tmp/$1.raw 2>/dev/null; else timeout 3 pw-record --target @DEFAULT_MONITOR@ --format s16 --channels 1 --rate 8000 - >/tmp/$1.raw 2>/dev/null; fi; true"
  ssh_guest "cat /tmp/$1.raw" >"$RUN_DIR/$1.raw" 2>/dev/null || true
  python3 -c '
import array, math, sys
raw = open(sys.argv[1], "rb").read()
data = array.array("h")
data.frombytes(raw[: len(raw) // 2 * 2])
print(f"{math.sqrt(sum(x * x for x in data) / len(data)) / 32768:.4f}" if data else "0")
' "$RUN_DIR/$1.raw"
}

start_vm_from_base
wait_for_ssh 300 failure-S5.4-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
check "setup starts on the welcome screen, with the soundtrack playing" until_json /api/setup '.setup.step == "welcome" and (.setup.muted | not)' 30
check "the player is on the TV (OCR)" ocr_finds success-S5.4-player "setup soundtrack|m to mute" 30
capture_console "success-S5.4-player"
guest "pactl list sink-inputs" >"$RUN_DIR/sink-inputs.txt" 2>&1 || true
check "the TV's page plays through the box's output" grep -qi "chrom" "$RUN_DIR/sink-inputs.txt"
playing=$(loudness playing)
check "S5.4 the soundtrack can be heard on the box's output (loudness $playing)" awk -v l="$playing" 'BEGIN { exit !(l > 0.005) }'

# A phone mutes it.
code=$(ssh_guest "curl -fsS -X POST http://127.0.0.1:3000/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
token=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\": \"$code\", \"name\": \"image check\"}' http://127.0.0.1:3001/api/phone/pair" 2>/dev/null | jq -r '.token // empty')
check "a phone pairs" test -n "$token"
ssh_guest "curl -fsS -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -d '{\"muted\": true}' http://127.0.0.1:3001/api/phone/setup-music" >"$RUN_DIR/mute.json" 2>&1 || true
check "S5.4 the phone mutes the soundtrack" until_json /api/setup '.setup.muted' 10
sleep 2
muted=$(loudness muted)
check "S5.4 and muted, the box's output goes quiet (loudness $playing, then $muted)" awk -v p="$playing" -v m="$muted" 'BEGIN { exit !(m < p / 4 && m < 0.003) }'
check "the player says it's muted (OCR)" ocr_finds success-S5.4-muted "muted" 30
capture_console "success-S5.4-muted"

# Setup done: home plays none.
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "setup done, home is in front${took:+ (after $took s)}" test -n "$took"

stop_vm
finish
