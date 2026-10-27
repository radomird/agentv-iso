#!/bin/bash
#
# The provider key on an installed box (ADR-009, S4.6). A key given to the
# daemon, as Settings → AI gives it, waits for its provider's terms when
# nobody has accepted them (Q104): a phone on the box's own address accepts
# them, as an adult, and the box records it. Then the key ends up in
# /etc/agentv/env, root's alone with mode 600: the user account can't read
# it, nothing of it stays in the daemon's state, key.json says which
# provider has one with no key in it, and no log has it. agentv selftest
# S4.6 says so too, and taking the key off takes its line out.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-key-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-key-no-tv"; check "the TV session came up" false; stop_vm; finish; }

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 3

# A made-up key in the shape of a real one.
KEY="sk-ant-api03-agentvimagecheck$(printf '0%.0s' {1..30})"
put_key() {
  ssh_guest "curl -sS --max-time 20 -X PUT -H 'Content-Type: application/json' -d '{\"provider\":\"claude\",\"key\":\"$KEY\"}' http://127.0.0.1:3000/api/key" >"$RUN_DIR/$1.json" 2>&1 || true
}

# Nobody has accepted Claude's terms for a key: the key waits for them, and
# a phone on the box's own address is asked to accept them.
put_key asked
check "Q104 a key for claude waits for claude's terms for a key" jq -e '.ok == false and .terms.provider == "claude" and .terms.terms[0].id == "anthropic-commercial-terms"' "$RUN_DIR/asked.json"
code=$(ssh_guest "curl -fsS -X POST http://127.0.0.1:3000/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
token=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\": \"$code\", \"name\": \"image check\"}' http://127.0.0.1:3001/api/phone/pair" 2>/dev/null | jq -r '.token // empty')
check "a phone pairs" test -n "$token"
ssh_guest "curl -fsS -H 'Authorization: Bearer $token' http://127.0.0.1:3001/api/phone/state" >"$RUN_DIR/phone.json" 2>&1 || true
check "the phone is asked to accept claude's terms for a key" jq -e '.ai.ask == "terms" and .ai.provider == "claude" and .ai.path == "key"' "$RUN_DIR/phone.json"
ssh_guest "curl -fsS -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -d '{\"provider\": \"claude\", \"path\": \"key\"}' http://127.0.0.1:3001/api/phone/terms" >"$RUN_DIR/accepted.json" 2>&1 || true
check "Q104 an adult accepts them on the phone" jq -e '.ok and .accepted.provider == "claude" and .accepted.path == "key" and .accepted.by.phone == "image check"' "$RUN_DIR/accepted.json"
recorded() {
  ssh_sudo "jq -e 'map(select(.provider == \"claude\" and .path == \"key\")) | length == 1' /var/lib/private/agentv/daemon/terms.json" >/dev/null
}
check "and the box records it in terms.json, the daemon's own" recorded

put_key stored
check "the daemon takes a key for claude and says it's kept" jq -e '.set == true and .provider == "claude"' "$RUN_DIR/stored.json"

root_only() {
  [[ $(ssh_sudo "stat -c '%U %a' /etc/agentv/env" 2>/dev/null) == "root 600" ]]
}
in_env() {
  [[ $(ssh_sudo "grep -c '^ANTHROPIC_API_KEY=$KEY\$' /etc/agentv/env" 2>/dev/null) == 1 ]]
}
unreadable() {
  ! ssh_guest "cat /etc/agentv/env" >/dev/null 2>&1
}
no_drop() {
  ssh_sudo "test ! -e /var/lib/private/agentv/daemon/key-drop/key.json"
}
status_only() {
  local status
  status=$(ssh_guest "cat /etc/agentv/key.json" 2>/dev/null) || return 1
  jq -e '.set == true and .provider == "claude"' <<<"$status" >/dev/null && [[ $status != *"$KEY"* ]]
}
check "S4.6 /etc/agentv/env is root's, with mode 600" root_only
check "it has the key" in_env
check "S4.6 the user account can't read it" unreadable
check "nothing of it stays in the daemon's state" no_drop
check "key.json says claude has a key, with no key in it" status_only

guest "agentv selftest S4.6" >"$RUN_DIR/selftest.log" 2>&1 || true
cat "$RUN_DIR/selftest.log"
check "agentv selftest S4.6 passes" grep -q "^pass S4.6 the claude key is root's alone" "$RUN_DIR/selftest.log"

ssh_sudo "journalctl -b --no-pager -u agentv-daemon -u agentv-key" >"$RUN_DIR/journal.log" 2>&1 || true
not_logged() {
  grep -q "a key for claude is kept, root's alone" "$RUN_DIR/journal.log" && ! grep -q "$KEY" "$RUN_DIR/journal.log"
}
check "the journal says a key is kept, and never has the key" not_logged

ssh_guest "curl -fsS --max-time 20 -X DELETE http://127.0.0.1:3000/api/key" >"$RUN_DIR/removed.json" 2>&1 || true
check "taking the key off says there's none" jq -e '.set == false' "$RUN_DIR/removed.json"
gone() {
  ! ssh_sudo "grep -q ANTHROPIC_API_KEY /etc/agentv/env"
}
check "and its line is gone from /etc/agentv/env" gone

stop_vm
finish
