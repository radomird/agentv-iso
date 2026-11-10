#!/bin/bash
#
# Who may read what on an installed box: the folders that hold keys,
# sign-ins and builds, each owned by who its units say and closed to
# everyone else. The key's file and the NAS passwords are root's alone, the
# TV's sign-ins the owner's alone, the builder's home the builder's alone,
# and the daemon's own state the daemon's alone. A build's folder,
# made the way the daemon asks root for one, is the builder's and its
# group's: the person's account and any other user can't read what a build
# saved, and the daemon and the builder's way out, which do read it, are in
# that group.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

DIR=/var/lib/agentv/build/local.modes/1.0.0
UNIT='agentv-builder@local.modes-1.0.0.service'
MARK="agentv-modes-$RANDOM$RANDOM"

start_vm_from_base
wait_for_ssh 300 failure-modes-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true

# "owner:group:mode" of a path, as root sees it.
is() { [[ $(ssh_guest "sudo stat -c %U:%G:%a '$1'" 2>/dev/null) == "$2" ]]; }
# Nothing for "other" in a path's mode: its last digit is 0.
# What the person's own account, with no sudo, can't do.
cannot() { ! ssh_guest "$1"; }
absent() { ! ssh_guest "sudo test -e '$1'"; }

ssh_guest "sudo stat -c '%n %U:%G:%a' /etc/agentv /etc/agentv/env /etc/agentv/shares /var/lib/agentv /var/lib/agentv/chromium /var/lib/agentv/builder /var/lib/agentv/build /var/lib/agentv/daemon /var/lib/agentv/backgrounds /var/lib/agentv/shared" >"$RUN_DIR/modes.txt" 2>&1 || true

check "/etc/agentv is root's, and only root writes it" is /etc/agentv root:root:755
check "the keys' file is root's alone" is /etc/agentv/env root:root:600
shares_closed() { absent /etc/agentv/shares || is /etc/agentv/shares root:root:700; }
check "the NAS passwords' folder, when there is one, is root's alone" shares_closed
check "the TV's sign-ins are the owner's alone" is /var/lib/agentv/chromium "$GUEST_USER:$GUEST_USER:700"
check "the builder's home is the builder's alone" is /var/lib/agentv/builder agentv-builder:agentv-builder:700
check "the builds' folder is root's, and only root writes it" is /var/lib/agentv/build root:root:755
check "the daemon's own state is the daemon's alone" is /var/lib/agentv/daemon agentv-server:agentv-server:700
# Nothing in /etc/agentv is writable by anyone but root, and nothing that
# holds a key or a password is readable by others.
ssh_guest "sudo find /etc/agentv \( -perm /022 -o ! -user root \) -print" >"$RUN_DIR/etc-writable.txt" 2>&1 || true
check "nothing in /etc/agentv is writable by anyone but root" test ! -s "$RUN_DIR/etc-writable.txt"
check "the person's account can't read the keys" cannot "cat /etc/agentv/env"
check "nor the builder's home" cannot "ls /var/lib/agentv/builder"
check "nor the daemon's state" cannot "ls /var/lib/agentv/daemon"

# A build, asked for the way the daemon asks. Its unit runs a probe in place
# of the builder, with every setting of the real one, the umask too.
ssh_guest "sudo -u agentv-builder env HOME=/var/lib/agentv/builder bash -c 'mkdir -p ~/.local/bin && printf \"#!/bin/sh\\n\" >~/.local/bin/claude && chmod 755 ~/.local/bin/claude'"
ssh_guest "sudo mkdir -p '/run/systemd/system/$UNIT.d' && printf '[Service]\nExecStart=\nExecStart=/usr/bin/bash /usr/local/share/agentv-modes-probe.sh\n' | sudo tee '/run/systemd/system/$UNIT.d/probe.conf' >/dev/null && sudo systemctl daemon-reload"
ssh_guest "sudo mkdir -p /usr/local/share && sudo tee /usr/local/share/agentv-modes-probe.sh >/dev/null && sudo chmod 644 /usr/local/share/agentv-modes-probe.sh" <<PROBE
#!/bin/bash
# As agentv-builder, in the build's sandbox: what a build saves.
mkdir -p $DIR/work/fixtures/pages
echo $MARK >$DIR/work/fixtures/pages/page.html
echo '{"build":"b1","id":"local.modes","version":"1.0.0","phase":"build","state":"running","steps":[],"started":"","at":""}' >$DIR/status.json
echo done >$DIR/probe.out
PROBE
ssh_guest "sudo install -d -m 700 /var/lib/agentv/daemon/build-drop && printf '%s' '{\"build\":\"b1\",\"id\":\"local.modes\",\"version\":\"1.0.0\",\"sentence\":\"a probe\",\"phase\":\"build\",\"recipe\":\"game\",\"provider\":\"claude\",\"path\":\"key\",\"safeguards\":true}' | sudo tee /var/lib/agentv/daemon/build-drop/start.json >/dev/null"

started=$SECONDS
while (( SECONDS - started < 240 )); do
  ssh_guest "sudo grep -q '^done' $DIR/probe.out" 2>/dev/null && break
  sleep 2
done
ssh_guest "cat /run/agentv-build/answer.json" >"$RUN_DIR/answer.json" 2>&1 || true
ssh_guest "sudo find /var/lib/agentv/build/local.modes -printf '%p %u:%g:%m\n'" >"$RUN_DIR/build-modes.txt" 2>&1 || true
ssh_guest "sudo journalctl -b -u agentv-build.service -u '$UNIT' --no-pager" >"$RUN_DIR/builder.log" 2>&1 || true

check "root's hand-over took the ask and started the build" jq -e '.build == "b1" and .started == true' "$RUN_DIR/answer.json"
check "the build ran and saved a page" ssh_guest "sudo grep -q $MARK $DIR/work/fixtures/pages/page.html"
check "a build's folder is the builder's and its group's, closed to everyone else" is "$DIR" agentv-builder:agentv-builder:750
check "a page a build saved is closed to everyone else" is "$DIR/work/fixtures/pages/page.html" agentv-builder:agentv-builder:640
check "and so are the folders it made" is "$DIR/work/fixtures" agentv-builder:agentv-builder:750
# A link's own mode is always 777 and means nothing, so links are left out.
ssh_guest "sudo find $DIR ! -type l -perm /007 -printf '%m %u:%g %p\n'" >"$RUN_DIR/build-open.txt" 2>&1 || true
# Said here, so a failed run's log names what was open.
[[ ! -s $RUN_DIR/build-open.txt ]] || sed 's/^/open to others: /' "$RUN_DIR/build-open.txt"
check "nothing in the build is open to other users" test ! -s "$RUN_DIR/build-open.txt"
check "the person's account can't read the saved page" cannot "cat $DIR/work/fixtures/pages/page.html"
check "nor list the build" cannot "ls $DIR"
check "nor can a user with no groups" cannot "sudo setpriv --reuid=65534 --regid=65534 --clear-groups cat $DIR/work/fixtures/pages/page.html"

# Who does read a build: the daemon, for its status and screenshot, and the
# builder's way out, for its filter and the nightly package check.
group_id=$(ssh_guest "getent group agentv-builder | cut -d: -f3" 2>/dev/null)
ssh_guest "sudo grep '^Groups:' /proc/\$(systemctl show -p MainPID --value agentv-daemon.service)/status" >"$RUN_DIR/daemon-groups.txt" 2>&1 || true
check "the daemon is in the builder's group" grep -Eq "(^|[[:space:]])$group_id([[:space:]]|\$)" "$RUN_DIR/daemon-groups.txt"
check "and that group is enough to read the build's status" ssh_guest "sudo setpriv --reuid=65534 --regid=65534 --groups=$group_id cat $DIR/status.json"
check "the builder's way out is in the builder's group" ssh_guest "id -nG agentv-build-net | tr ' ' '\n' | grep -qx agentv-builder"
check "and reads the build as itself" ssh_guest "sudo -u agentv-build-net cat $DIR/status.json"
check "the builder's group opens nothing of the builder's home" cannot "sudo -u agentv-build-net ls /var/lib/agentv/builder"

ssh_guest "sudo rm -rf /var/lib/agentv/build/local.modes '/run/systemd/system/$UNIT.d' /usr/local/share/agentv-modes-probe.sh; sudo systemctl daemon-reload" || true

stop_vm
finish
