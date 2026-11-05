#!/bin/bash
#
# Grok and Muse on an installed box (ADR-047, S4.6, Q104), with stand-in
# keys. For each, a key given to the daemon, as Settings → AI gives it,
# waits for its maker's terms for a key: a phone on the box's own address
# accepts them, as an adult, and the box records it. Then the key ends up in
# /etc/agentv/env under the name its CLI reads (XAI_API_KEY, META_API_KEY),
# root's alone with mode 600, and key.json names the provider with no key in
# it. A second key for it just saves, with no new acceptance. One provider
# has a key at a time.

# shellcheck disable=SC2016 # $p and $t are jq's
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-grok-muse-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-grok-muse-no-tv"; check "the TV session came up" false; stop_vm; finish; }

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 3

code=$(ssh_guest "curl -fsS -X POST http://127.0.0.1:3000/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
token=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\": \"$code\", \"name\": \"image check\"}' http://127.0.0.1:3001/api/phone/pair" 2>/dev/null | jq -r '.token // empty')
check "a phone pairs" test -n "$token"

# A key as Settings → AI gives it: its provider, the key, and where the
# answer goes.
put_key() {
  ssh_guest "curl -sS --max-time 20 -X PUT -H 'Content-Type: application/json' -d '{\"provider\":\"$1\",\"key\":\"$2\"}' http://127.0.0.1:3000/api/key" >"$RUN_DIR/$3.json" 2>&1 || true
}
accepted() {
  [[ $(ssh_sudo "jq 'map(select(.provider == \"$1\" and .path == \"key\")) | length' /var/lib/private/agentv/daemon/terms.json" 2>/dev/null) == "$2" ]]
}
root_only() {
  [[ $(ssh_sudo "stat -c '%U %a' /etc/agentv/env" 2>/dev/null) == "root 600" ]]
}
in_env() {
  [[ $(ssh_sudo "grep -c '^$1=$2\$' /etc/agentv/env" 2>/dev/null) == 1 ]]
}
kept_as() {
  in_env "$1" "$2" && root_only
}
not_in_env() {
  ! ssh_sudo "grep -q '^$1=' /etc/agentv/env"
}
named() {
  local status
  status=$(ssh_guest "cat /etc/agentv/key.json" 2>/dev/null) || return 1
  jq -e --arg p "$1" '.set == true and .provider == $p' <<<"$status" >/dev/null && [[ $status != *"$2"* ]]
}

# One provider: its name, the variable its CLI reads, the id of its terms
# for a key, and two stand-in keys in the shape of its real ones.
provider() {
  local name=$1 var=$2 terms=$3 key=$4 again=$5

  put_key "$name" "$key" "$name-asked"
  check "ADR-047 Q104 a key for $name waits for $name's terms for a key" \
    jq -e --arg p "$name" --arg t "$terms" '.ok == false and .terms.provider == $p and .terms.terms[0].id == $t' "$RUN_DIR/$name-asked.json"
  ssh_guest "curl -fsS -H 'Authorization: Bearer $token' http://127.0.0.1:3001/api/phone/state" >"$RUN_DIR/$name-phone.json" 2>&1 || true
  check "the phone is asked to accept $name's terms for a key" \
    jq -e --arg p "$name" '.ai.ask == "terms" and .ai.provider == $p and .ai.path == "key"' "$RUN_DIR/$name-phone.json"
  ssh_guest "curl -fsS -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -d '{\"provider\": \"$name\", \"path\": \"key\"}' http://127.0.0.1:3001/api/phone/terms" >"$RUN_DIR/$name-accepted.json" 2>&1 || true
  check "an adult accepts them on the phone" \
    jq -e --arg p "$name" '.ok and .accepted.provider == $p and .accepted.path == "key" and .accepted.by.phone == "image check"' "$RUN_DIR/$name-accepted.json"
  check "and the box records it in terms.json, the daemon's own" accepted "$name" 1

  put_key "$name" "$key" "$name-stored"
  check "S4.6 the daemon takes a key for $name and says it's kept" jq -e --arg p "$name" '.set == true and .provider == $p' "$RUN_DIR/$name-stored.json"
  check "S4.6 it's $var in /etc/agentv/env, root's with mode 600" kept_as "$var" "$key"
  check "key.json names $name, with no key in it" named "$name" "$key"

  put_key "$name" "$again" "$name-again"
  check "ADR-047 a second key for $name just saves" jq -e --arg p "$name" '.set == true and .provider == $p' "$RUN_DIR/$name-again.json"
  check "in the first one's place" in_env "$var" "$again"
  check "with no new acceptance" accepted "$name" 1
}

provider grok XAI_API_KEY xai-enterprise-terms "xai-agentvimagecheck$(printf '0%.0s' {1..40})" "xai-agentvimagecheck$(printf '1%.0s' {1..40})"
provider muse META_API_KEY meta-model-api-terms "LLM_agentvimagecheck$(printf '0%.0s' {1..40})" "LLM_agentvimagecheck$(printf '1%.0s' {1..40})"
check "one provider has a key at a time: muse's took grok's place" not_in_env XAI_API_KEY

ssh_sudo "journalctl -b --no-pager -u agentv-daemon -u agentv-key" >"$RUN_DIR/journal.log" 2>&1 || true
not_logged() {
  ! grep -q "agentvimagecheck" "$RUN_DIR/journal.log"
}
check "no log has either key" not_logged

ssh_guest "curl -fsS --max-time 20 -X DELETE http://127.0.0.1:3000/api/key" >"$RUN_DIR/removed.json" 2>&1 || true
check "taking the key off says there's none" jq -e '.set == false' "$RUN_DIR/removed.json"
check "and its line is gone from /etc/agentv/env" not_in_env META_API_KEY

stop_vm
finish
