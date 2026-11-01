#!/bin/bash
#
# The router on an installed box (ADR-013, ADR-022, ADR-023, S7.3, and the
# sandbox S7.4 runs in). Its two services run, with sockets only the
# agentv-router group reaches: the daemon is in it, the person's account
# isn't. In place of the plan's CLI, a probe with every sandbox setting of
# agentv-router-cli.service, as agentv-builder, tries the key, the TV's
# sign-ins, the internet and this box, and its way out lets a plan's
# provider through and refuses anything else. Then sentences end to end:
# with no AI set up, the TV says what's missing; with a key and a stand-in
# for Anthropic's API, one that can't be routed is "i didn't get that", one
# that can is looked up in the box's apps, the key reaches the provider
# only through the router, and the journal has neither the key nor what
# was said.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

UNIT=agentv-router-cli.service
HOME_DIR=/var/lib/agentv/builder
MARK="agentv-router-$RANDOM$RANDOM"
STANDIN_PORT=8777
DROPINS=/run/systemd/system

start_vm_from_base
wait_for_ssh 300 failure-S7-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 3

# --- The two services, and who reaches them ----------------------------------

check "the router's services run" ssh_guest "systemctl is-active --quiet agentv-router.service && systemctl is-active --quiet $UNIT"
check "the router has a user of its own" ssh_guest "id agentv-router"
ssh_sudo "stat -c '%n %U %G %a' /run/agentv-router /run/agentv-router/router.sock /run/agentv-router/cli-net.sock /run/agentv-router-cli/route.sock" >"$RUN_DIR/sockets.txt" 2>&1 || true
socket() { grep -qx "$1" "$RUN_DIR/sockets.txt"; }
check "the router's folder is its own and its group's" socket "/run/agentv-router agentv-router agentv-router 750"
check "S7.4 the key's router answers the agentv-router group only" socket "/run/agentv-router/router.sock agentv-router agentv-router 660"
check "S7.4 and so does the plan's CLI's way out" socket "/run/agentv-router/cli-net.sock agentv-router agentv-router 660"
check "S7.4 and the plan's router" socket "/run/agentv-router-cli/route.sock agentv-builder agentv-router 660"
unreachable() {
  ! ssh_guest "curl -sS --max-time 5 --unix-socket $1 -X POST -d '{}' http://router/route" >/dev/null 2>&1
}
check "the person's account can't ask the key's router" unreachable /run/agentv-router/router.sock
check "nor the plan's" unreachable /run/agentv-router-cli/route.sock
in_group() {
  local pid gid
  pid=$(ssh_guest "systemctl show -p MainPID --value agentv-daemon.service")
  gid=$(ssh_guest "getent group agentv-router | cut -d: -f3")
  [[ -n $gid ]] && ssh_sudo "grep '^Groups:' /proc/$pid/status" | grep -qw "$gid"
}
check "the daemon is in the agentv-router group, which is how it asks" in_group

# --- The plan's CLI's sandbox, probed ----------------------------------------

ssh_guest "sudo bash -c 'umask 077; grep -v ^ANTHROPIC_API_KEY= /etc/agentv/env >/tmp/env 2>/dev/null; echo ANTHROPIC_API_KEY=sk-ant-api03-$MARK >>/tmp/env; install -m 600 /tmp/env /etc/agentv/env; rm -f /tmp/env'"
ssh_guest "sudo install -D -m 644 /dev/null /var/lib/agentv/chromium/$MARK"
ssh_guest "sudo systemctl restart agentv-router.service"
ssh_guest "sudo install -m 644 /dev/null $HOME_DIR/router-probe.sh && sudo install -m 644 -o agentv-builder -g agentv-builder /dev/null $HOME_DIR/router-probe.out"
ssh_guest "sudo tee $HOME_DIR/router-probe.sh >/dev/null" <<PROBE
#!/bin/bash
# As agentv-builder, in agentv-router-cli's sandbox. Each line: yes or no.
out=$HOME_DIR/router-probe.out
: >"\$out"
say() { if eval "\$2" >/dev/null 2>&1; then echo "yes \$1" >>"\$out"; else echo "no \$1" >>"\$out"; fi; }
say user '[ "\$(id -un)" = agentv-builder ]'
say group 'id -nG | grep -qw agentv-router'
say env 'cat /etc/agentv/env'
say credential 'cat /run/credentials/agentv-router.service/env'
say key-anywhere 'grep -ra $MARK /proc/*/environ'
say chromium 'cat /var/lib/agentv/chromium/$MARK'
say private 'ls /var/lib/private'
say daemon-state 'ls /var/lib/agentv/daemon'
say home 'touch $HOME_DIR/$MARK'
say internet 'curl -sS --max-time 5 -o /dev/null https://1.1.1.1/'
say daemon 'curl -sS --max-time 5 -o /dev/null http://127.0.0.1:3000/'
node --disable-warning=ExperimentalWarning --input-type=module -e "const { forward } = await import('/usr/share/agentv/builder/sandbox/forward.ts'); await forward(8080, '/run/agentv-router/cli-net.sock'); setTimeout(() => process.exit(0), 30000);" &
sleep 2
say provider '[ "\$(curl -sS --max-time 15 -o /dev/null -w %{http_connect} -x http://127.0.0.1:8080 https://api.anthropic.com/ 2>/dev/null)" = 200 ]'
say github-refused 'curl -sS --max-time 10 -o /dev/null -x http://127.0.0.1:8080 https://github.com/ 2>&1 | grep -q 403'
say registry-refused 'curl -sS --max-time 10 -o /dev/null -x http://127.0.0.1:8080 https://registry.npmjs.org/ 2>&1 | grep -q 403'
say box 'curl -sS --max-time 10 -o /dev/null -x http://127.0.0.1:8080 https://127.0.0.1:3000/'
echo done >>"\$out"
PROBE
ssh_guest "sudo mkdir -p '$DROPINS/$UNIT.d' && printf '[Service]\nExecStart=\nExecStart=/usr/bin/bash $HOME_DIR/router-probe.sh\nRestart=no\n' | sudo tee '$DROPINS/$UNIT.d/probe.conf' >/dev/null && sudo systemctl daemon-reload && sudo systemctl restart $UNIT"
started=$SECONDS
while (( SECONDS - started < 120 )); do
  ssh_guest "sudo grep -q '^done' $HOME_DIR/router-probe.out" 2>/dev/null && break
  sleep 2
done
ssh_guest "sudo cat $HOME_DIR/router-probe.out" >"$RUN_DIR/probe.txt" 2>&1 || true
ssh_guest "sudo systemd-analyze security $UNIT" >"$RUN_DIR/security.txt" 2>&1 || true
said() { grep -qx "$1 $2" "$RUN_DIR/probe.txt"; }
check "the probe ran as agentv-builder" said yes user
check "in the agentv-router group, for its way out" said yes group
check "S7.4 the plan's CLI can't read /etc/agentv/env" said no env
check "S7.4 nor the router's credential" said no credential
check "S7.4 and the key isn't in any process it can see" said no key-anywhere
check "S7.4 nor can it read the TV's sign-ins" said no chromium
check "S7.4 nor other services' state" said no private
check "S7.4 nor the daemon's" said no daemon-state
check "it writes the builder's home, where the plan's sign-in lives" said yes home
check "S7.4 it has no network of its own" said no internet
check "S7.4 nor can it reach the daemon" said no daemon
check "its way out lets a plan's provider through" said yes provider
check "S7.4 and refuses anything else: GitHub" said yes github-refused
check "S7.4 the npm registry" said yes registry-refused
check "S7.4 and this box" said no box
ssh_guest "sudo rm -f '${DROPINS:?}/${UNIT:?}.d/probe.conf' && sudo systemctl daemon-reload && sudo systemctl restart $UNIT && sudo rm -f '${HOME_DIR:?}/router-probe.sh' '${HOME_DIR:?}/router-probe.out' '${HOME_DIR:?}/${MARK:?}'"
check "the plan's router runs again once the probe is gone" ssh_guest "sleep 2; systemctl is-active --quiet $UNIT"

# --- A sentence, end to end ----------------------------------------------------

ssh_guest "sudo bash -c 'grep -v ^ANTHROPIC_API_KEY= /etc/agentv/env >/tmp/env; install -m 600 /tmp/env /etc/agentv/env; rm -f /tmp/env'"
say_it() {
  ssh_guest "curl -sS --max-time 60 -H 'Content-Type: application/json' -d '{\"sentence\": \"$1\"}' http://127.0.0.1:3000/api/say" >"$RUN_DIR/$2.json" 2>&1 || true
}
say_it "play frozen" no-ai
check "S7.3 with no AI set up, a sentence does nothing, and the TV says what's missing" jq -e '.said.outcome.kind == "none" and .said.outcome.detail == "set up your agent in settings → ai first"' "$RUN_DIR/no-ai.json"

# A stand-in for Anthropic's API on the box: it answers the router's
# brief as the model would, and keeps the key it was sent.
ssh_guest "cat >/tmp/standin.mjs" <<'STANDIN'
import { createServer } from "node:http";
import { writeFileSync } from "node:fs";
const none = { intent: "none", query: null, kind: null, app: null, season: null, episode: null };
createServer(async (request, response) => {
  let body = "";
  for await (const chunk of request) body += chunk;
  writeFileSync("/tmp/standin-key", String(request.headers["x-api-key"] ?? ""));
  const asked = JSON.parse(body || "{}");
  const said = String(asked.messages?.[0]?.content ?? "");
  const route = said.includes("frozen soundtrack") ? { ...none, intent: "play", query: "Frozen", kind: "album" } : none;
  response.writeHead(200, { "Content-Type": "application/json" });
  response.end(JSON.stringify({ type: "message", model: asked.model, content: [{ type: "text", text: JSON.stringify(route) }], stop_reason: "end_turn", usage: { input_tokens: 1500, output_tokens: 40 } }));
}).listen(Number(process.argv[2]), "127.0.0.1");
STANDIN
ssh_guest "nohup node /tmp/standin.mjs $STANDIN_PORT >/tmp/standin.log 2>&1 </dev/null & disown" || true
ssh_guest "sudo mkdir -p $DROPINS/agentv-router.service.d && printf '[Service]\nEnvironment=AGENTV_ROUTER_UPSTREAM=http://127.0.0.1:$STANDIN_PORT\n' | sudo tee $DROPINS/agentv-router.service.d/standin.conf >/dev/null && sudo systemctl daemon-reload && sudo systemctl restart agentv-router.service"

# A key, as Settings → AI keeps it, with Anthropic's terms accepted on a
# phone first (Q104).
KEY="sk-ant-api03-agentvroutercheck$(printf '0%.0s' {1..30})"
put_key() {
  ssh_guest "curl -sS --max-time 20 -X PUT -H 'Content-Type: application/json' -d '{\"provider\":\"claude\",\"key\":\"$KEY\"}' http://127.0.0.1:3000/api/key" >"$RUN_DIR/$1.json" 2>&1 || true
}
put_key asked
code=$(ssh_guest "curl -fsS -X POST http://127.0.0.1:3000/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
token=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\": \"$code\", \"name\": \"image check\"}' http://127.0.0.1:3001/api/phone/pair" 2>/dev/null | jq -r '.token // empty')
ssh_guest "curl -fsS -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -d '{\"provider\": \"claude\", \"path\": \"key\"}' http://127.0.0.1:3001/api/phone/terms" >"$RUN_DIR/accepted.json" 2>&1 || true
put_key stored
check "a key for claude is kept, as Settings → AI keeps it" jq -e '.set == true and .provider == "claude"' "$RUN_DIR/stored.json"
# agentv-key.service starts the router again with the key; give it a moment.
sleep 3

say_it "turn the lights off" unroutable
check "S7.3 a sentence that can't be routed is i didn't get that" jq -e '.said.route.intent == "none" and .said.outcome.kind == "none" and .said.outcome.why == "unroutable" and .said.outcome.say == "i didn'"'"'t get that"' "$RUN_DIR/unroutable.json"
say_it "put on the frozen soundtrack" routed
check "a sentence that can be routed goes from the phone's words to the provider and back" jq -e '.said.route.intent == "play" and .said.route.query == "Frozen" and .said.route.kind == "album"' "$RUN_DIR/routed.json"
check "and is looked up in the box's apps, where Music hasn't got it" jq -e '.said.outcome.why == "not-found" and .said.outcome.say == "i couldn'"'"'t find frozen"' "$RUN_DIR/routed.json"
check "the key reached the provider, through the router" ssh_guest "grep -qx '$KEY' /tmp/standin-key"
guest "agentv selftest S7.3" >"$RUN_DIR/selftest.log" 2>&1 || true
cat "$RUN_DIR/selftest.log"
check "agentv selftest S7.3 passes" grep -q '^pass S7.3 "the cat sat on the" came back as i didn' "$RUN_DIR/selftest.log"

ssh_sudo "journalctl -b --no-pager -u agentv-daemon -u agentv-router -u agentv-router-cli -u agentv-key" >"$RUN_DIR/journal.log" 2>&1 || true
not_logged() {
  grep -q "routed by claude" "$RUN_DIR/journal.log" && ! grep -q -e "$KEY" -e "$MARK" -e "lights off" -e "frozen soundtrack" -e "cat sat" "$RUN_DIR/journal.log"
}
check "the journal says what was routed and how fast, and never the key or what was said" not_logged

ssh_guest "sudo rm -f '${DROPINS:?}/agentv-router.service.d/standin.conf' && sudo systemctl daemon-reload; pkill -f standin.mjs" || true
stop_vm
finish
