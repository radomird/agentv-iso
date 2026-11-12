#!/bin/bash
#
# The phone companion on an installed box (stage 4). The daemon listens for
# phones on port 3001, which the firewall opens to the home network only. A
# phone on the box's own address pairs with the code the TV shows, and its
# d-pad and typed text reach the home screen through the screen daemon and
# the virtual input device. Settings → Phones shows the code and its QR code.
#
# The phone signs and seals what it sends, so the box's own agentv-phone-call
# stands in for it. A request with no signature, or with only a token as
# phones once sent, gets nothing.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-phone-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-phone-no-tv"; check "the TV session came up" false; stop_vm; finish; }

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

listening() {
  ssh_guest "ss -Hltn" 2>/dev/null | awk '{print $4}' | grep -Eq '^(0\.0\.0\.0|\*|\[::\]):3001$'
}
check "the daemon listens for phones on port 3001" listening
ssh_sudo "ufw status" >"$RUN_DIR/ufw.txt" 2>&1 || true
cat "$RUN_DIR/ufw.txt"
home_only() {
  grep -Eq '^3001/tcp +ALLOW +192\.168\.0\.0/16' "$RUN_DIR/ufw.txt" && ! grep -Eq '^3001(/tcp)? +ALLOW +Anywhere' "$RUN_DIR/ufw.txt"
}
check "the firewall opens it to the home network, and not to anywhere" home_only

address=$(ssh_guest "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -n 1" 2>/dev/null || true)
log "The box's address: ${address:-none}"

# Settings → Phones → pair a phone, from the TV.
guest "agentv screen settings phones" >"$RUN_DIR/settings.json" 2>&1 || true
sleep 2
guest "agentv input key enter" >"$RUN_DIR/input.log" 2>&1 || true
sleep 1
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 3
capture_console "success-phone-pair"
pairing=$(ssh_guest "curl -fsS http://127.0.0.1:3000/api/phones" 2>/dev/null || true)
code=$(jq -r '.pairing.code // empty' <<<"$pairing")
check "the TV shows a code to pair with" test -n "$code"
own_address() {
  [[ $(jq -r '.pairing.url // empty' <<<"$pairing") == "http://$address:3001/" ]]
}
check "and its address is the box's own on the network" own_address
qr() {
  ssh_guest "curl -fsS http://127.0.0.1:3000/api/phones/qr" 2>/dev/null | grep -q "<svg"
}
check "with a QR code, drawn by qrencode" qr
# Read for up to 10 s. check keeps what it runs quiet, so what OCR read is
# printed after it, when it didn't find it.
before=$FAILURES
check "the pairing screen says pair a phone (OCR)" ocr_finds pair "pair a phone" 10
if (( FAILURES > before )); then
  capture_console "failure-phone-pair-ocr"
  log "What OCR read on the pairing screen:"
  cat "$RUN_DIR/pair.txt"
  log "What the screen daemon says is in front:"
  screen_status
  print_screen "$RUN_DIR/.ocr.ppm"
fi

# The phone, on the box's own address as a phone on the network reaches it.
phone="http://$address:3001"
page=$(ssh_guest "curl -fsS $phone/" 2>/dev/null || true)
check "the phone companion's page is there on the network" grep -q "companion-web/main.ts" <<<"$page"
# A name and an icon, for a phone's home screen when the remote is added to
# it: the page names them, and the box serves them.
home_screen() {
  grep -q 'rel="manifest" href="/companion-web/manifest.json"' <<<"$page" &&
    jq -e '.name == "AgenTV" and (.icons | length > 0)' <<<"$(ssh_guest "curl -fsS $phone/companion-web/manifest.json" 2>/dev/null)" >/dev/null &&
    [[ $(ssh_guest "curl -s -o /dev/null -w '%{content_type}' $phone/companion-web/icon-180.png" 2>/dev/null) == "image/png" ]]
}
check "with a name and an icon for a phone's home screen" home_screen
not_tv() {
  [[ $(ssh_guest "curl -s -o /dev/null -w '%{http_code}' $phone/api/home" 2>/dev/null) != "200" ]]
}
check "and nothing of the TV's own is" not_tv
# The code sent as it is, the way phones once paired, is a wrong try and
# pairs nothing.
old_pair() {
  [[ $(ssh_guest "curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{\"code\":\"$code\",\"name\":\"old phone\"}' $phone/api/phone/pair" 2>/dev/null) == "403" ]]
}
check "the code sent in the clear pairs nothing" old_pair
phone_key=$(ssh_guest "AGENTV_PHONE_URL=$phone agentv-phone-call pair '$code' 'test phone'" 2>/dev/null || true)
check "the phone pairs with the code" test -n "$phone_key"
key_file() {
  [[ $(ssh_guest "stat -c %a $phone_key" 2>/dev/null) == "600" ]]
}
check "and keeps a key of its own" key_file
signed_state() {
  [[ $(ssh_guest "AGENTV_PHONE_URL=$phone agentv-phone-call $phone_key GET /api/phone/state" 2>/dev/null | jq -r '.phone.name // empty') == "test phone" ]]
}
check "a request it signs is answered" signed_state
# Without a signature there's no answer, token or not.
unsigned() {
  local header=""
  [[ -n ${1:-} ]] && header="-H 'Authorization: Bearer $1'"
  [[ $(ssh_guest "curl -s -o /dev/null -w '%{http_code}' $header $phone/api/phone/state" 2>/dev/null) == "401" ]]
}
check "a request with no signature is refused" unsigned
check "and so is one with only a token" unsigned "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
# What's kept on the box is the phone's key, in a file only the daemon reads.
stored() {
  [[ $(ssh_sudo "stat -L -c %a /var/lib/agentv/daemon/phones.json" 2>/dev/null) == "600" ]] &&
    ssh_sudo "cat /var/lib/agentv/daemon/phones.json" 2>/dev/null | jq -e '.phones | length > 0 and all(.[]; (.key | type == "string") and (has("token") | not))' >/dev/null
}
check "the box keeps the phone's key, and no token, in a file only the daemon reads" stored
sleep 2
check "Settings → Phones lists it" jq -e '.phones | map(.name) | index("test phone") != null' <<<"$(ssh_guest "curl -fsS http://127.0.0.1:3000/api/phones")"

# Its d-pad and keyboard reach the home screen.
guest "agentv screen home" >/dev/null 2>&1 || true
sleep 2
guest "agentv screen keys 8" >"$RUN_DIR/keys.json" 2>&1 &
keys=$!
sleep 2
for body in '{"key":"down"}' '{"key":"right"}' '{"text":"tv"}'; do
  ssh_guest "AGENTV_PHONE_URL=$phone agentv-phone-call $phone_key POST /api/phone/remote '$body'" >>"$RUN_DIR/remote.log" 2>&1 || true
  sleep 0.5
done
wait "$keys" || true
cat "$RUN_DIR/keys.json"
check "the phone's d-pad reaches the home screen" jq -e '.keys | index("ArrowDown") != null and index("ArrowRight") != null' "$RUN_DIR/keys.json"
check "and so does what it types" jq -e '.keys | index("t") != null and index("v") != null' "$RUN_DIR/keys.json"

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen.log" 2>&1 || true
check "the screen daemon took them without an error" bash -c "! grep -q 'phone input:' '$RUN_DIR/screen.log'"

stop_vm
finish
