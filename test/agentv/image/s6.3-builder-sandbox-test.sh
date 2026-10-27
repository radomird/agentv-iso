#!/bin/bash
#
# The builder's sandbox on an installed box (ADR-011, ADR-045, S6.3, and
# S6.8's "the builder can't push to GitHub"). A build is asked for the way
# the daemon asks: root's hand-over checks it, makes its folder and ticket,
# restarts the builder's way out and starts agentv-builder@ for it. For
# this check, the build's unit runs a probe instead of the builder, with
# every sandbox setting of the real one. The probe, as agentv-builder, tries
# what a misled agent or a bad package would: the key in /etc/agentv/env,
# the TV's sign-ins, other services' state, the person's home, sudo, the
# OS's files, the network on its own, this box, GitHub, and the relay's key.
# Then a package's install script, as it runs with safeguards off.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

DIR=/var/lib/agentv/build/local.probe/1.0.0
UNIT='agentv-builder@local.probe-1.0.0.service'
MARK="agentv-probe-$RANDOM$RANDOM"

start_vm_from_base
wait_for_ssh 300 failure-S6.3-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true

home_shut() { ! ssh_guest "ls /var/lib/agentv/builder" >/dev/null 2>&1; }
# sudo -l -U lists what a user may run with sudo, and says so when there's
# nothing. Its answer is kept with the run.
ssh_guest "sudo -l -U agentv-builder" >"$RUN_DIR/sudo-list.txt" 2>&1 || true
no_sudo() { [[ -s $RUN_DIR/sudo-list.txt ]] && ! grep -qiE "may run|NOPASSWD|ALL\)" "$RUN_DIR/sudo-list.txt"; }
check "the builder has its own user, with a home only it reads" ssh_guest "id agentv-builder && test \"\$(stat -c %U:%a /var/lib/agentv/builder)\" = agentv-builder:700"
check "the person's account can't read the builder's home" home_shut
check "the builder may run nothing with sudo" no_sudo

# What it mustn't see: a key, and marks anyone could read but for the
# sandbox, in the TV's sign-ins, the keys' folder and the person's home.
ssh_guest "sudo bash -c 'umask 077; grep -v ^ANTHROPIC_API_KEY= /etc/agentv/env >/tmp/env 2>/dev/null; echo ANTHROPIC_API_KEY=sk-ant-api03-$MARK >>/tmp/env; install -m 600 /tmp/env /etc/agentv/env; rm -f /tmp/env'"
ssh_guest "sudo install -D -m 644 /dev/null /var/lib/agentv/chromium/$MARK && echo $MARK | sudo tee /var/lib/agentv/chromium/$MARK /etc/agentv/$MARK >/dev/null && sudo chmod 644 /etc/agentv/$MARK && echo $MARK >~/$MARK && chmod 644 ~/$MARK"

# The CLI's there already, so nothing is fetched, and the build's unit
# runs the probe in place of the builder, sandbox and all.
ssh_guest "sudo -u agentv-builder env HOME=/var/lib/agentv/builder bash -c 'mkdir -p ~/.local/bin && printf \"#!/bin/sh\\n\" >~/.local/bin/claude && chmod 755 ~/.local/bin/claude'"
ssh_guest "sudo install -d -m 755 /var/lib/agentv/build/local.probe && sudo install -d -m 755 -o agentv-builder -g agentv-builder $DIR"
ssh_guest "sudo mkdir -p '/run/systemd/system/$UNIT.d' && printf '[Service]\nExecStart=\nExecStart=/usr/bin/bash $DIR/probe.sh\n' | sudo tee '/run/systemd/system/$UNIT.d/probe.conf' >/dev/null && sudo systemctl daemon-reload"
ssh_guest "sudo tee $DIR/probe.sh >/dev/null && sudo chmod 644 $DIR/probe.sh" <<PROBE
#!/bin/bash
# As agentv-builder, in the build's sandbox. Each line: yes or no, and what.
out=$DIR/probe.out
: >"\$out"
say() { if eval "\$2" >/dev/null 2>&1; then echo "yes \$1" >>"\$out"; else echo "no \$1" >>"\$out"; fi; }
say user '[ "\$(id -un)" = agentv-builder ]'
say env 'cat /etc/agentv/env'
say etc-mark 'cat /etc/agentv/$MARK'
say chromium 'cat /var/lib/agentv/chromium/$MARK'
say chromium-dir 'ls /var/lib/agentv/chromium'
say private 'ls /var/lib/private'
say home 'cat /home/*/$MARK'
say sudo 'sudo -n true'
say wheel 'id -nG | grep -qw wheel'
say usr 'touch /usr/share/agentv/$MARK'
say etc 'touch /etc/$MARK'
say own 'touch $DIR/$MARK'
say internet 'curl -sS --max-time 5 -o /dev/null https://1.1.1.1/'
say daemon 'curl -sS --max-time 5 -o /dev/null http://127.0.0.1:3000/'
say credential 'cat /run/credentials/agentv-build-net.service/env'
say relay-env 'grep -a $MARK /proc/*/environ'
# A package's install script with safeguards off runs in bubblewrap, in the
# jail packages.ts builds: the builder's home, with its CLI, out of sight,
# and only the work folder to write.
mkdir -p $DIR/work
mapfile -t jail < <(node --disable-warning=ExperimentalWarning --input-type=module -e "const { jail } = await import('/usr/share/agentv/builder/packages.ts'); console.log(jail('$DIR/work', '/var/lib/agentv/builder').join('\\n'))")
say bwrap 'bwrap "\${jail[@]}" true'
say bwrap-home 'bwrap "\${jail[@]}" test -e /var/lib/agentv/builder/.local/bin/claude'
say bwrap-work 'bwrap "\${jail[@]}" touch $DIR/work/$MARK'
say bwrap-build 'bwrap "\${jail[@]}" touch $DIR/$MARK-outside-work'
say bwrap-env 'bwrap "\${jail[@]}" cat /etc/agentv/env'
# The way out, as the builder reaches it.
node --disable-warning=ExperimentalWarning --input-type=module -e "const { forward } = await import('/usr/share/agentv/builder/sandbox/start.ts'); await forward(8080, '/run/agentv-build-net/proxy.sock'); setTimeout(() => process.exit(0), 20000);" &
sleep 2
say github '[ "\$(curl -sS --max-time 10 -o /dev/null -w %{http_code} -x http://127.0.0.1:8080 https://github.com/ 2>/dev/null)" = 200 ]'
say github-refused 'curl -sS --max-time 10 -o /dev/null -x http://127.0.0.1:8080 https://github.com/ 2>&1 | grep -q 403'
say box-through-filter 'curl -sS --max-time 10 -o /dev/null -x http://127.0.0.1:8080 https://127.0.0.1:3000/'
say relay-refuses 'curl -sS --max-time 10 --unix-socket /run/agentv-build-net/relay.sock http://relay/v1/files | grep -q "isn.t a call the builder makes"'
echo done >>"\$out"
PROBE

# The daemon's ask, as root's hand-over takes it.
ssh_guest "sudo install -d -m 700 /var/lib/private/agentv/daemon/build-drop && printf '%s' '{\"build\":\"b1\",\"id\":\"local.probe\",\"version\":\"1.0.0\",\"sentence\":\"a probe\",\"phase\":\"build\",\"recipe\":\"game\",\"provider\":\"claude\",\"path\":\"key\",\"safeguards\":true}' | sudo tee /var/lib/private/agentv/daemon/build-drop/start.json >/dev/null"

started=$SECONDS
while (( SECONDS - started < 120 )); do
  ssh_guest "sudo grep -q '^done' $DIR/probe.out" 2>/dev/null && break
  sleep 2
done
ssh_guest "cat /run/agentv-build/answer.json" >"$RUN_DIR/answer.json" 2>&1 || true
ssh_guest "sudo cat $DIR/probe.out" >"$RUN_DIR/probe.txt" 2>&1 || true
ssh_guest "sudo journalctl -b -u agentv-build.service -u agentv-build-net.service -u '$UNIT' --no-pager" >"$RUN_DIR/builder.log" 2>&1 || true
ssh_guest "sudo systemd-analyze security '$UNIT'" >"$RUN_DIR/security.txt" 2>&1 || true

said() { grep -qx "$1 $2" "$RUN_DIR/probe.txt"; }
check "root's hand-over took the ask and started the build's sandbox" jq -e '.build == "b1" and .started == true' "$RUN_DIR/answer.json"
check "the probe ran as agentv-builder" said yes user
check "S6.3 the builder can't read /etc/agentv/env" said no env
check "S6.3 or anything else in /etc/agentv, even what anyone may read" said no etc-mark
check "S6.3 the builder can't read another service's cookies: the TV's sign-ins aren't there to it" said no chromium
check "S6.3 nor list them" said no chromium-dir
check "S6.3 other services' private state isn't there to it" said no private
check "S6.3 nor is the person's home" said no home
check "the builder has no sudo" said no sudo
check "the builder isn't in wheel" said no wheel
check "the OS's files stay root's: AgenTV's own" said no usr
check "the OS's files stay root's: /etc" said no etc
check "the builder writes its own build's folder" said yes own
check "the builder has no network of its own" said no internet
check "the builder can't reach the daemon" said no daemon
check "the builder can't read the relay's key" said no credential
check "the key isn't in any process the builder can see" said no relay-env
check "S6.8 the builder can't push to GitHub: its filter refuses github.com" said yes github-refused
check "S6.8 so nothing from GitHub reaches it" said no github
check "the filter won't take it to this box either" said no box-through-filter
check "the relay passes on only a model's calls" said yes relay-refuses
check "ADR-044 bubblewrap runs in the builder's sandbox, for install scripts with safeguards off" said yes bwrap
check "ADR-044 an install script can't see the builder's home, its CLI or a plan's sign-in" said no bwrap-home
check "ADR-044 an install script writes the work folder" said yes bwrap-work
check "ADR-044 and nothing else of the build" said no bwrap-build
check "ADR-044 nor reads the key" said no bwrap-env
check "ADR-044 the nightly package check is on" ssh_guest "systemctl is-enabled --quiet agentv-npm-check.timer"
check "the build's unit ended, and its ticket with it" ssh_guest "! systemctl is-active --quiet '$UNIT' && ! test -e /run/agentv-build/ticket.json"

stop_vm
finish
