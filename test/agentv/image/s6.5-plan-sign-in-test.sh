#!/bin/bash
#
# A plan's sign-in on an installed box (ADR-040, S6.5's "no copy of the
# plan's tokens exists outside Claude Code's own files"). The daemon asks
# for the sign-in the way it does when a build on a plan finds none: root's
# hand-over makes the sign-in's folder and the filter's ticket, and starts
# agentv-builder-sign-in@claude in the builder's sandbox. A stand-in for
# Claude Code's login, in the builder's home where the real one would be,
# prints its link and reads the code the phone hands over, then keeps its
# token in its own credentials file. Nothing else on the box may have it.
# The real login, with a real plan, is the NUC's (S6.5).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

MARK="agentv-plan-$RANDOM$RANDOM"
TOKEN="sk-ant-oat01-$MARK"
HOME_DIR=/var/lib/agentv/builder
DROP=/var/lib/private/agentv/daemon/build-drop
RUN=/run/agentv-build
UNIT='agentv-builder-sign-in@claude.service'

start_vm_from_base
wait_for_ssh 300 failure-S6.5-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true

# The stand-in login, as agentv-builder put it there: a link, a prompt for
# the code, and the token in its own file once the code is right.
ssh_guest "sudo -u agentv-builder tee $HOME_DIR/stand-in-claude >/dev/null" <<CLI
#!/bin/bash
creds="\$HOME/.claude/.credentials.json"
if [[ \$1 == auth && \$2 == status ]]; then
  if [[ -f \$creds ]]; then echo '{"loggedIn": true, "authMethod": "claude.ai"}'; exit 0; fi
  echo '{"loggedIn": false}'; exit 1
fi
[[ \$1 == auth && \$2 == login && \$3 == --claudeai ]] || exit 2
id -un >"\$HOME/signed-in-as"
printf 'Browser didn'"'"'t open? Use the url below to sign in:\n\nhttps://claude.ai/oauth/authorize?code=true&client_id=stand-in&state=s7Q\n\n'
printf 'Paste code here if prompted > '
read -r code
[[ \$code == "good-code#s7Q" ]] || { echo "OAuth error: invalid code"; exit 1; }
mkdir -p "\$HOME/.claude"
umask 077
printf '{"claudeAiOauth": {"accessToken": "$TOKEN"}}' >"\$creds"
echo "Login successful."
CLI
ssh_guest "sudo -u agentv-builder bash -c 'mkdir -p $HOME_DIR/.local/bin && install -m 755 $HOME_DIR/stand-in-claude $HOME_DIR/.local/bin/claude && rm $HOME_DIR/stand-in-claude'"

# The daemon's ask, as root's hand-over takes it.
ssh_guest "sudo install -d -m 700 $DROP && printf '%s' '{\"build\":\"b1\",\"provider\":\"claude\"}' | sudo tee $DROP/sign-in.json >/dev/null"
state() { ssh_guest "sudo jq -r .state $RUN/sign-in/status.json" 2>/dev/null; }
started=$SECONDS
while (( SECONDS - started < 120 )) && [[ $(state) != waiting && $(state) != failed ]]; do sleep 2; done
ssh_guest "sudo cat $RUN/sign-in/status.json" >"$RUN_DIR/waiting.json" 2>&1 || true
ssh_guest "sudo cat $RUN/answer.json" >"$RUN_DIR/answer.json" 2>&1 || true
ssh_guest "sudo cat $RUN/sign-in.json" >"$RUN_DIR/ticket.json" 2>&1 || true

# The code the person pasted on the phone, as the daemon hands it over.
ssh_guest "printf '%s' '{\"code\":\"good-code#s7Q\"}' | sudo tee $DROP/sign-in-code.json >/dev/null"
started=$SECONDS
while (( SECONDS - started < 60 )) && [[ $(state) != "done" && $(state) != failed ]]; do sleep 2; done
ssh_guest "sudo cat $RUN/sign-in/status.json" >"$RUN_DIR/done.json" 2>&1 || true
sleep 2
ssh_guest "sudo journalctl -b -u agentv-build.service -u agentv-build-net.service -u '$UNIT' --no-pager" >"$RUN_DIR/sign-in.log" 2>&1 || true
ssh_guest "sudo systemd-analyze security '$UNIT'" >"$RUN_DIR/security.txt" 2>&1 || true

# Everywhere the token could have gone but the CLI's own file (and the
# stand-in, which plays the provider's side too), and the whole journal.
ssh_guest "sudo grep -rlsF '$MARK' /var/lib/agentv /var/lib/private /run /etc /home /tmp /var/tmp /var/log --exclude-dir=journal | grep -vxF -e '$HOME_DIR/.claude/.credentials.json' -e '$HOME_DIR/.local/bin/claude'" >"$RUN_DIR/copies.txt" 2>&1 || true
no_copies() { [[ ! -s $RUN_DIR/copies.txt ]]; }
not_in_journal() { ! ssh_guest "sudo journalctl -b --no-pager | grep -qF -e '$MARK' -e good-code"; }

check "root's hand-over took the ask and started the sign-in" jq -e '.action == "sign-in" and .build == "b1" and .started == true' "$RUN_DIR/answer.json"
check "the filter's sign-in ticket is for the plan's provider" jq -e '.provider == "claude" and .path == "plan"' "$RUN_DIR/ticket.json"
check "ADR-040 the CLI's link shows, whole, for the TV's QR code and the phone" jq -e '.state == "waiting" and .url == "https://claude.ai/oauth/authorize?code=true&client_id=stand-in&state=s7Q" and .pastes == true' "$RUN_DIR/waiting.json"
check "ADR-040 the phone's code reaches the CLI's prompt, and it's signed in" jq -e '.state == "done" and (has("url") | not)' "$RUN_DIR/done.json"
check "the CLI signed in as agentv-builder, in its own home" ssh_guest "sudo test \"\$(sudo cat $HOME_DIR/signed-in-as)\" = agentv-builder && sudo test \"\$(sudo stat -c %U:%a $HOME_DIR/.claude/.credentials.json)\" = agentv-builder:600"
check "S6.5 no copy of the plan's tokens exists outside the CLI's own files" no_copies
check "S6.5 nor in the journal, and the code isn't logged" not_in_journal
check "the code is gone once it's typed" ssh_guest "! sudo test -e $RUN/sign-in/input"
check "the sign-in's unit ended, and the filter's ticket with it" ssh_guest "! systemctl is-active --quiet '$UNIT' && ! test -e $RUN/sign-in.json"

stop_vm
finish
