#!/bin/bash
#
# The desktop's password, set from Settings on an installed box (T7.4). A box
# set up from the USB stick's first screen has an account nobody knows the
# password of, and first boot leaves SSH taking keys only. This makes that
# account on the base image, as the first screen leaves it: agentv, with a
# locked password, the first screen's note and first boot's keys-only
# drop-in. Then the TV's own route, with setup's own switch on, sets a
# password made up here, through root's socket. The check reads it back
# against /etc/shadow, sees SSH taking passwords again, and looks for the
# password in the journal. The test VM keeps SSH to keys only with a
# setting of its own (00-omarchy-vm.conf) that comes before every other, so
# here the check sees the box take its own drop-in away and reload sshd. A
# password over SSH is the NUC's check.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

TV=http://127.0.0.1:3000

start_vm_from_base
wait_for_ssh 300 failure-T7.4-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo

# The account as the USB stick's first screen leaves it, and first boot's
# keys-only SSH (install/tv/account.sh), applied.
ssh_guest "sudo useradd -m -s /bin/bash agentv && sudo usermod -p '!' agentv" >"$RUN_DIR/account.log" 2>&1 || true
ssh_guest "sudo tee /var/lib/agentv/account.json >/dev/null && sudo chmod 644 /var/lib/agentv/account.json" <<<'{"name": "agentv", "passwordKnown": false}'
ssh_guest "sudo bash -c 'set -euo pipefail; source /usr/share/agentv/install/tv/account.sh' && sudo systemctl reload sshd.service" >>"$RUN_DIR/account.log" 2>&1 || true
check "first boot keeps SSH to keys only while nobody knows the password" ssh_guest "grep -qx 'PasswordAuthentication no' /etc/ssh/sshd_config.d/05-agentv-no-password.conf"

# Setup's own switch on, as on an edge box that tries it.
ssh_guest "curl -sS -X PUT -H 'Content-Type: application/json' -d '{\"setup2\": true}' $TV/api/features" >"$RUN_DIR/features.json" 2>&1 || true
check "setup's own switch is on" jq -e '.setup2 == true' "$RUN_DIR/features.json"
ssh_guest "curl -sS $TV/api/desktop/password" >"$RUN_DIR/before.json" 2>&1 || true
check "T7.4 Settings sees the account with no password known" jq -e '.password == {"managed": true, "name": "agentv", "known": false}' "$RUN_DIR/before.json"

# A throwaway password, made up here, sent on stdin so it's on no command
# line, in the request's body as the TV's page sends it.
password="t74 $(head -c 12 /dev/urandom | base64 | tr -d '/+=')"
jq -Rc '{password: .}' <<<"$password" |
  ssh_guest "curl -sS --max-time 60 -X PUT -H 'Content-Type: application/json' --data-binary @- $TV/api/desktop/password" >"$RUN_DIR/set.json" 2>&1 || true
check "T7.4 the TV's route sets it, through root's socket" jq -e '.ok == true and .password.known == true' "$RUN_DIR/set.json"

# The password against /etc/shadow, with libc's own crypt, whatever hash the
# box uses. Perl reads the password on stdin.
same_password() {
  [[ $(ssh_guest "sudo perl -e 'my \$typed = <STDIN>; chomp \$typed; my \$hash = (getpwnam(\"agentv\"))[1]; print crypt(\$typed, \$hash) eq \$hash ? \"same\" : \"different\"'" <<<"$password") == "same" ]]
}
check "T7.4 the account's password is the one typed" same_password
check "the account note says a password is known" ssh_guest "jq -e '.passwordKnown == true' /var/lib/agentv/account.json"
check "and SSH's keys-only drop-in is gone" ssh_guest "! test -e /etc/ssh/sshd_config.d/05-agentv-no-password.conf"

ssh_sudo "journalctl -b --no-pager" >"$RUN_DIR/journal.log" 2>&1 || true
# sshd read its settings again after root set the password, without the
# drop-in.
reloaded_after() {
  awk '/agentv-password-set: agentv.s password is set/ { set = 1 } set && /sshd\[[0-9]+\]: Received SIGHUP/ { found = 1 } END { exit !found }' "$RUN_DIR/journal.log"
}
check "T7.4 and sshd took that in, so SSH takes passwords again" reloaded_after
not_logged() { ! grep -qF -- "${password#t74 }" "$RUN_DIR/journal.log"; }
check "T7.4 the journal doesn't have the password" not_logged
grep -h 'agentv-password-set\|desktop.s password' "$RUN_DIR/journal.log" >"$RUN_DIR/password.log" || true

stop_vm
finish
