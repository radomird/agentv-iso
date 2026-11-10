#!/bin/bash
#
# The TV says its answers aloud on an installed box (stage 8, Q146, the
# spoken half of S7.3), with a sound card that plays to nothing, as S2.19's
# check has. Piper and its cori voice come in the agentv-voice package, on
# the box from its first boot (Q157), root's and readable by anyone. A
# Claude key has no voice of its own, so the very first "i didn't get that"
# is made by Piper on the box and played by the TV session through
# PipeWire, the daemon's log says which voice, and nothing logs the words.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

ROUTER_PORT=8777
DROPINS=/run/systemd/system

# start_vm_from_base, with a sound card.
qemu-img create -f qcow2 -b "$BASE_DISK" -F qcow2 "$RUN_DIR/run.qcow2" >/dev/null
cp "$BASE_OVMF" "$RUN_DIR/OVMF_VARS.4m.fd"
# shellcheck disable=SC2034 # start_vm reads it
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/serial.log" -audiodev none,id=snd0 -device intel-hda -device hda-output,audiodev=snd0
wait_for_ssh 300 failure-S8-voice-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-S8-voice-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 3

check "agentv-voice is installed, as agentv needs it" ssh_guest "pacman -Q agentv-voice && pacman -Qi agentv | sed -n '/^Depends On/,/^Optional Deps/p' | grep -qw agentv-voice"
ssh_guest "stat -c '%n %U %a' /usr/lib/agentv-voice/piper/piper /usr/lib/agentv-voice/en_GB-cori-medium.onnx" >"$RUN_DIR/voice-files.txt" 2>&1 || true
# Compared in bash: the test container has no diff.
files=$(printf '%s\n' "/usr/lib/agentv-voice/piper/piper root 755" "/usr/lib/agentv-voice/en_GB-cori-medium.onnx root 644")
check "Piper is root's, and anyone can read it" test "$(cat "$RUN_DIR/voice-files.txt")" = "$files"

# A stand-in for Anthropic's API, which can't route anything, and a key
# for Claude with its terms accepted on a phone (Q104).
ssh_guest "cat >/tmp/router-standin.mjs" <<'STANDIN'
import { createServer } from "node:http";
const none = { intent: "none", query: null, kind: null, app: null, season: null, episode: null };
createServer(async (request, response) => {
  for await (const chunk of request) void chunk;
  response.writeHead(200, { "Content-Type": "application/json" });
  response.end(JSON.stringify({ type: "message", content: [{ type: "text", text: JSON.stringify(none) }], stop_reason: "end_turn", usage: { input_tokens: 1500, output_tokens: 40 } }));
}).listen(Number(process.argv[2]), "127.0.0.1");
STANDIN
ssh_guest "nohup node /tmp/router-standin.mjs $ROUTER_PORT >/tmp/router-standin.log 2>&1 </dev/null & disown" || true
ssh_guest "sudo mkdir -p $DROPINS/agentv-router.service.d && printf '[Service]\nEnvironment=AGENTV_ROUTER_UPSTREAM=http://127.0.0.1:$ROUTER_PORT\n' | sudo tee $DROPINS/agentv-router.service.d/standin.conf >/dev/null && sudo systemctl daemon-reload && sudo systemctl restart agentv-router.service"
KEY="sk-ant-api03-agentvvoicecheck$(printf '0%.0s' {1..30})"
put_key() {
  ssh_guest "curl -sS --max-time 20 -X PUT -H 'Content-Type: application/json' -d '{\"provider\":\"claude\",\"key\":\"$KEY\"}' http://127.0.0.1:3000/api/key" >"$RUN_DIR/$1.json" 2>&1 || true
}
put_key asked
code=$(ssh_guest "curl -fsS -X POST http://127.0.0.1:3000/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
phone_key=$(ssh_guest "agentv-phone-call pair '$code' 'image check'" 2>/dev/null || true)
ssh_guest "agentv-phone-call $phone_key POST /api/phone/terms '{\"provider\": \"claude\", \"path\": \"key\"}'" >/dev/null 2>&1 || true
put_key stored
check "a key for claude is kept for the router" jq -e '.set == true and .provider == "claude"' "$RUN_DIR/stored.json"
sleep 3

say_it() {
  ssh_guest "curl -sS --max-time 60 -H 'Content-Type: application/json' -d '{\"sentence\": \"the cat sat on the\"}' http://127.0.0.1:3000/api/say" >"$RUN_DIR/$1.json" 2>&1 || true
}
voice() {
  ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/voice" 2>/dev/null || echo '{}'
}

# --- The first answer is said ------------------------------------------------------

voice >"$RUN_DIR/voice-new.json"
check "the daemon has Piper ready on a new box" jq -e '.piper == "ready" and .by == "piper"' "$RUN_DIR/voice-new.json"
before=$(voice | jq -r '.last.clip // 0')
say_it first
check "S7.3 a sentence that can't be routed is i didn't get that" jq -e '.said.outcome.say == "i didn'"'"'t get that"' "$RUN_DIR/first.json"
started=$SECONDS
until voice | jq -e --argjson before "$before" '(.last.clip // 0) > $before and .last.played != null' >/dev/null || (( SECONDS - started > 60 )); do sleep 1; done
voice >"$RUN_DIR/voice.json"
cat "$RUN_DIR/voice.json"
check "S7.3 the TV says i didn't get that aloud, with Piper on the box" jq -e '.by == "piper" and .last.by == "piper" and .last.played == true' "$RUN_DIR/voice.json"
check "Piper made it in under 5 s" jq -e '.last.ms < 5000' "$RUN_DIR/voice.json"

guest "agentv selftest S7.3" >"$RUN_DIR/selftest.log" 2>&1 || true
cat "$RUN_DIR/selftest.log"
check "agentv selftest S7.3 says the TV said it, with piper" grep -q '^pass S7.3 the TV said it aloud, with piper' "$RUN_DIR/selftest.log"

ssh_sudo "journalctl -b --no-pager -u agentv-daemon -u agentv-router" >"$RUN_DIR/journal.log" 2>&1 || true
said_with_piper() {
  grep -qE "the tv said its answer with piper, made in [0-9]+ ms$" "$RUN_DIR/journal.log" && ! grep -q -e "cat sat" -e "$KEY" "$RUN_DIR/journal.log"
}
check "the journal says the TV said it with piper, and never the words or the key" said_with_piper

ssh_guest "sudo rm -f '${DROPINS:?}/agentv-router.service.d/standin.conf' && sudo systemctl daemon-reload; pkill -f router-standin.mjs" || true
stop_vm
finish
