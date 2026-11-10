#!/bin/bash
#
# A plan signed in at setup's AI step, and voice that answers before any
# build (T7.3). Setup is brought to its AI step through the daemon, as the
# TV's pages move it, and Claude's plan is picked, with its terms accepted
# on a paired phone. Then setup's own route starts the plan's sign-in, with
# no build: root's hand-over starts agentv-builder-sign-in@claude in the
# builder's sandbox, and a stand-in for Claude Code, in the builder's home
# where the real one would be, prints its link and reads the code the phone
# hands over through the daemon. Once it's in, setup goes on, and a sentence
# is routed by the plan's CLI, through the router's own service, with no
# build on the box. The real login, with a real plan, is the NUC's.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

HOME_DIR=/var/lib/agentv/builder
RUN=/run/agentv-build
TV=http://127.0.0.1:3000
PHONE=http://127.0.0.1:3001

start_vm_from_base
wait_for_ssh 300 failure-T7.3-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo

# The stand-in for Claude Code, as agentv-builder put it there. Its sign-in
# prints a link and reads the code, its status says whether it's in, and a
# run with -p answers the router's brief as the model would: a route, as
# Claude Code's one JSON result. Each run notes who ran it.
ssh_guest "sudo -u agentv-builder tee $HOME_DIR/stand-in-claude >/dev/null" <<'CLI'
#!/bin/bash
creds="$HOME/.claude/.credentials.json"
if [[ $1 == auth && $2 == status ]]; then
  if [[ -f $creds ]]; then echo '{"loggedIn": true, "authMethod": "claude.ai"}'; exit 0; fi
  echo '{"loggedIn": false}'; exit 1
fi
if [[ $1 == auth && $2 == login && $3 == --claudeai ]]; then
  printf 'Browser didn'"'"'t open? Use the url below to sign in:\n\nhttps://claude.ai/oauth/authorize?code=true&client_id=stand-in&state=t73\n\n'
  printf 'Paste code here if prompted > '
  read -r code
  [[ $code == "good-code#t73" ]] || { echo "OAuth error: invalid code"; exit 1; }
  mkdir -p "$HOME/.claude"
  umask 077
  printf '{"claudeAiOauth": {"accessToken": "stand-in"}}' >"$creds"
  echo "Login successful."
  exit 0
fi
if [[ $1 == -p ]]; then
  echo "$(id -un) $(date +%s)" >>"$HOME/routed-by"
  [[ -f $creds ]] || { echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in · Please run /login"}'; exit 1; }
  if [[ $2 == *"frozen soundtrack"* ]]; then
    route='{"intent":"play","query":"Frozen","kind":"album","app":null,"season":null,"episode":null}'
  else
    route='{"intent":"none","query":null,"kind":null,"app":null,"season":null,"episode":null}'
  fi
  printf '{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":%s,"modelUsage":{"claude-haiku-5-5":{}}}\n' "$route"
  exit 0
fi
exit 2
CLI
ssh_guest "sudo -u agentv-builder bash -c 'mkdir -p $HOME_DIR/.local/bin && install -m 755 $HOME_DIR/stand-in-claude $HOME_DIR/.local/bin/claude && rm $HOME_DIR/stand-in-claude'"

tv_post() {
  ssh_guest "curl -sS --max-time 30 -X ${3:-POST} -H 'Content-Type: application/json' -d '$2' $TV$1"
}

# Setup on its AI step, as the TV's pages move it there.
tv_post /api/setup/finish '{"step": "welcome"}' >/dev/null 2>&1 || true
tv_post /api/setup/ready '{"update": "none"}' >/dev/null 2>&1 || true
tv_post /api/setup/finish '{"step": "ready"}' >/dev/null 2>&1 || true
tv_post /api/setup/finish '{"step": "box"}' >/dev/null 2>&1 || true
tv_post /api/setup/finish '{"step": "country"}' >/dev/null 2>&1 || true
ssh_guest "curl -sS $TV/api/setup" >"$RUN_DIR/setup.json" 2>&1 || true
check "setup is on its AI step" jq -e '.setup.step == "ai" and .setup.done == false' "$RUN_DIR/setup.json"

# Claude's plan, with its terms accepted on a paired phone.
tv_post /api/ai '{"provider": "claude", "path": "plan"}' >"$RUN_DIR/picked.json" 2>&1 || true
code=$(ssh_guest "curl -fsS -X POST $TV/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
token=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\": \"$code\", \"name\": \"image check\"}' $PHONE/api/phone/pair" 2>/dev/null | jq -r '.token // empty')
ssh_guest "curl -sS -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -d '{\"provider\": \"claude\", \"path\": \"plan\"}' $PHONE/api/phone/terms" >"$RUN_DIR/accepted.json" 2>&1 || true
check "Claude's plan is picked, with its terms accepted on the phone" jq -e '.ok == true' "$RUN_DIR/accepted.json"

# The sign-in, started from setup's AI step, with no build.
tv_post /api/ai/sign-in '{}' >"$RUN_DIR/started.json" 2>&1 || true
check "setup's AI step starts the plan's sign-in" jq -e '.signIn.provider == "claude" and .signIn.signedIn == false' "$RUN_DIR/started.json"
sign_in() { ssh_guest "curl -sS $TV/api/ai/sign-in" 2>/dev/null | jq -r 'if .signIn.signedIn then "in" else (.signIn.now.state // "none") end'; }
started=$SECONDS
while (( SECONDS - started < 180 )) && [[ $(sign_in) != waiting && $(sign_in) != failed ]]; do sleep 2; done
ssh_guest "curl -sS $TV/api/ai/sign-in" >"$RUN_DIR/waiting.json" 2>&1 || true
ssh_guest "sudo cat $RUN/answer.json" >"$RUN_DIR/answer.json" 2>&1 || true
check "root's hand-over took setup's ask, with no build" jq -e '.action == "sign-in" and .build == null and .started == true' "$RUN_DIR/answer.json"
check "T7.3 the TV has the CLI's link for its QR code" jq -e '.signIn.now.state == "waiting" and .signIn.now.url == "https://claude.ai/oauth/authorize?code=true&client_id=stand-in&state=t73" and .signIn.now.pastes == true' "$RUN_DIR/waiting.json"
qr_drawn() { ssh_guest "curl -fsS $TV/api/ai/sign-in/qr" | grep -q '<svg'; }
check "and draws it as a QR code" qr_drawn

# The code the provider's page gave, pasted on the phone.
ssh_guest "curl -sS -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -d '{\"code\": \"good-code#t73\"}' $PHONE/api/phone/ai/sign-in/code" >"$RUN_DIR/code.json" 2>&1 || true
check "the phone hands over the code" jq -e '.ok == true' "$RUN_DIR/code.json"
started=$SECONDS
while (( SECONDS - started < 90 )) && [[ $(sign_in) != in && $(sign_in) != failed ]]; do sleep 2; done
ssh_guest "curl -sS $TV/api/ai/sign-in" >"$RUN_DIR/signed-in.json" 2>&1 || true
check "T7.3 the plan is signed in, from setup" jq -e '.signIn.signedIn == true' "$RUN_DIR/signed-in.json"
check "the CLI signed in as agentv-builder, in its own home" ssh_guest "sudo test \"\$(sudo stat -c %U:%a $HOME_DIR/.claude/.credentials.json)\" = agentv-builder:600"

# On through setup, then a sentence, with no build on the box.
tv_post /api/setup/finish '{"step": "ai"}' >"$RUN_DIR/after-ai.json" 2>&1 || true
check "setup moves on past the AI step" jq -e '.setup.step == "people"' "$RUN_DIR/after-ai.json"
guest "agentv setup skip" >"$RUN_DIR/setup-skip.log" 2>&1 || true
sleep 2
ssh_guest "curl -sS --max-time 60 -H 'Content-Type: application/json' -d '{\"sentence\": \"put on the frozen soundtrack\"}' $TV/api/say" >"$RUN_DIR/said.json" 2>&1 || true
check "T7.3 voice answers before any build: the plan's CLI routes the sentence" jq -e '.said.route.intent == "play" and .said.route.query == "Frozen" and .said.route.kind == "album"' "$RUN_DIR/said.json"
check "through the router's CLI service, as agentv-builder" ssh_guest "sudo grep -q '^agentv-builder ' $HOME_DIR/routed-by"
ssh_guest "curl -sS $TV/api/builds" >"$RUN_DIR/builds.json" 2>&1 || true
check "and there's no build on the box" jq -e '(.builds // []) | length == 0' "$RUN_DIR/builds.json"

ssh_sudo "journalctl -b --no-pager -u agentv-daemon -u agentv-build -u agentv-build-net -u 'agentv-builder-sign-in@*' -u agentv-router -u agentv-router-cli" >"$RUN_DIR/journal.log" 2>&1 || true
not_logged() { ! grep -q -e "good-code" -e "frozen soundtrack" "$RUN_DIR/journal.log"; }
check "the journal has neither the code nor what was said" not_logged

stop_vm
finish
