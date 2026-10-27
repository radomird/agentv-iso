#!/bin/bash
#
# S5.5: picking Claude in setup shows Anthropic's terms for the way in picked,
# nothing of it installs until an adult accepts them on a phone, and the box
# records the acceptance (ADR-023). Then Claude Code arrives the way Omarchy
# brings it: Omarchy's own wrapper fetches Anthropic's published binary on
# its first run.
#
# The TV is driven with its keys, as from the remote: on from the welcome
# screen and getting ready to the AI step, Claude, then its plan. A phone on
# the box's own address pairs and accepts, as the web companion does.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# until_json <url path> <jq filter> <seconds>: until the filter on what the
# daemon answers there is true.
until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000$1" 2>/dev/null | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 2
  done
  return 1
}

start_vm_from_base
wait_for_ssh 300 failure-S5.5-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
check "setup starts on the welcome screen" until_json /api/setup '.setup.step == "welcome"' 30

# On to the AI step with the keyboard: Enter on the welcome screen, then
# getting ready moves on once it's checked for a newer agentv.
guest "agentv input key enter" >"$RUN_DIR/input.log" 2>&1 || true
check "getting ready moves on to the AI step" until_json /api/setup '.setup.step == "ai"' 400
check "the AI step is on the TV (OCR)" ocr_finds success-S5.5-pick "which ai do you use|pick one" 30
capture_console "success-S5.5-pick"

# What mise has before anything's accepted, for the record.
ssh_guest "bash -lc 'mise ls --installed 2>&1'" >"$RUN_DIR/mise-before.txt" 2>&1 || true
check "Claude Code isn't on the box before its terms are accepted" bash -c "! grep -qi claude '$RUN_DIR/mise-before.txt'"

# Claude, then its plan, the first of each.
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 2
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
check "S5.5 picking Claude and a plan shows the terms for a plan" until_json /api/ai '.provider == "claude" and .path == "plan" and .accepted == null' 30
check "S5.5 they're Anthropic's consumer terms, its usage policy and Claude Code's legal notes" \
  until_json /api/ai '[.offers.claude.terms.plan[].id] == ["anthropic-consumer-terms", "anthropic-usage-policy", "claude-code-legal"]' 10
check "S5.5 the terms are on the TV (OCR)" ocr_finds success-S5.5-terms "consumer terms|the terms first" 30
capture_console "success-S5.5-terms"
sleep 20
check "S5.5 nothing installs while they wait for an adult" until_json /api/ai '.cli == null' 5
ssh_guest "bash -lc 'mise ls --installed 2>&1'" >"$RUN_DIR/mise-waiting.txt" 2>&1 || true
check "S5.5 and Claude Code still isn't on the box" bash -c "! grep -qi claude '$RUN_DIR/mise-waiting.txt'"

# A phone on the box's own address pairs, hears the terms and accepts them.
code=$(ssh_guest "curl -fsS -X POST http://127.0.0.1:3000/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
token=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\": \"$code\", \"name\": \"image check\"}' http://127.0.0.1:3001/api/phone/pair" 2>/dev/null | jq -r '.token // empty')
check "a phone pairs" test -n "$token"
# phone <path> [<json>]: the phone's request, with its token.
phone() {
  local data=""
  [[ -n ${2:-} ]] && data="-d '$2'"
  ssh_guest "curl -fsS -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' $data http://127.0.0.1:3001$1" 2>/dev/null
}
phone /api/phone/state >"$RUN_DIR/phone-state.json" || true
check "S5.5 the phone is asked to accept Claude's terms for a plan" \
  jq -e '.ai.ask == "terms" and .ai.provider == "claude" and .ai.path == "plan"' "$RUN_DIR/phone-state.json"
phone /api/phone/terms '{"provider": "claude", "path": "plan"}' >"$RUN_DIR/accepted.json" || true
check "S5.5 the box records the acceptance: which terms, who, on which phone, and when" \
  until_json /api/ai '.accepted.provider == "claude" and .accepted.path == "plan" and .accepted.by.phone == "image check" and (.accepted.at | test("^[0-9]{4}-")) and (.accepted.terms[0].id == "anthropic-consumer-terms")' 10
ssh_sudo "cat /var/lib/private/agentv/daemon/terms.json 2>/dev/null || cat /var/lib/agentv/daemon/terms.json" >"$RUN_DIR/terms.json" 2>&1 || true
check "S5.5 and keeps it in terms.json" jq -e 'length == 1 and .[0].by.phone == "image check"' "$RUN_DIR/terms.json"

# Then Claude Code arrives, through Omarchy's own wrapper.
log "Waiting for Claude Code's first run"
until_json /api/ai '.cli.state == "ready" or .cli.state == "failed"' 900 || true
ssh_guest "curl -fsS http://127.0.0.1:3000/api/ai" >"$RUN_DIR/ai.json" 2>&1 || true
check "S5.5 once they're accepted, Claude Code arrives on its first run ($(jq -r '"\(.cli.state // "nothing"): \(.cli.version // .cli.error // "")"' "$RUN_DIR/ai.json" 2>/dev/null))" \
  jq -e '.cli.state == "ready" and .cli.cli == "claude"' "$RUN_DIR/ai.json"
check "and claude runs for the owner" guest "claude --version"
# A plan signs in at the first build (ADR-040): the TV says it's ready.
check "the TV says it's ready, with the terms accepted (OCR)" ocr_finds success-S5.5-done "ready\\.|terms accepted" 30
capture_console "success-S5.5-done"

stop_vm
finish
