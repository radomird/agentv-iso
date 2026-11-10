#!/bin/bash
#
# The builder's home on an installed box, as a build sees it. A build is
# asked for the way the daemon asks, and its unit runs a probe in place of
# the builder, with every sandbox setting of the real one. The probe, as
# agentv-builder, tries what code that got loose in a build would: change
# the provider's CLI, mise's tree or config, or the CLI's own settings file,
# or move one of their folders aside for another. None of it works, while
# what a CLI writes as it runs still does. Then the app's own worker, as the
# contract tests start it: under bubblewrap, where the home, the plan's
# sign-in in it and the build's saved pages aren't there at all, and the
# real worker still starts.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

HOME_DIR=/var/lib/agentv/builder
DIR=/var/lib/agentv/build/local.home/1.0.0
UNIT='agentv-builder@local.home-1.0.0.service'
MARK="agentv-home-$RANDOM$RANDOM"

start_vm_from_base
wait_for_ssh 300 failure-builder-home-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true

# The home as it is after a CLI was fetched and a plan signed in: a CLI, a
# mise config, and a sign-in, each with a mark. The folders are tmpfiles'.
ssh_guest "sudo find $HOME_DIR -maxdepth 3 -printf '%p %u:%g:%m\n'" >"$RUN_DIR/home-before.txt" 2>&1 || true
check "the package made the home's folders, for the units to hold on to" ssh_guest "sudo test -d $HOME_DIR/.local/bin -a -d $HOME_DIR/.local/share/mise -a -d $HOME_DIR/.local/state/mise -a -d $HOME_DIR/.config/mise -a -d $HOME_DIR/.config/muse -a -d $HOME_DIR/.claude"
check "and the CLI's own settings file, the builder's, with nothing in it" ssh_guest "test \"\$(sudo stat -c %U:%a $HOME_DIR/.claude/settings.json)\" = agentv-builder:600 && test \"\$(sudo cat $HOME_DIR/.claude/settings.json)\" = '{}'"
ssh_guest "sudo -u agentv-builder env HOME=$HOME_DIR bash -c 'printf \"#!/bin/sh\\n# $MARK\\n\" >~/.local/bin/claude && chmod 755 ~/.local/bin/claude && echo \"# $MARK\" >~/.config/mise/config.toml && echo $MARK >~/.local/share/mise/installed && (umask 077; echo $MARK >~/.claude/.credentials.json)'"

ssh_guest "sudo mkdir -p '/run/systemd/system/$UNIT.d' && printf '[Service]\nExecStart=\nExecStart=/usr/bin/bash /usr/local/share/agentv-home-probe.sh\n' | sudo tee '/run/systemd/system/$UNIT.d/probe.conf' >/dev/null && sudo systemctl daemon-reload"
ssh_guest "sudo mkdir -p /usr/local/share && sudo tee /usr/local/share/agentv-home-probe.sh >/dev/null && sudo chmod 644 /usr/local/share/agentv-home-probe.sh" <<PROBE
#!/bin/bash
# As agentv-builder, in the build's sandbox. Each line: yes or no, and what.
out=$DIR/probe.out
: >"\$out"
say() { if eval "\$2" >/dev/null 2>&1; then echo "yes \$1" >>"\$out"; else echo "no \$1" >>"\$out"; fi; }
cd ~
say user '[ "\$(id -un)" = agentv-builder ]'
say cli-runs '~/.local/bin/claude'
# The CLI and where it sits.
say cli-write 'echo "# changed" >>~/.local/bin/claude'
say cli-remove 'rm -f ~/.local/bin/claude && ! test -e ~/.local/bin/claude'
say cli-new 'touch ~/.local/bin/codex'
say cli-swap 'mv ~/.local/bin ~/.local/bin.aside'
say local-swap 'mv ~/.local ~/.local.aside'
say local-new 'mkdir ~/.local/other'
# mise's tree and its config.
say mise-tree 'touch ~/.local/share/mise/added'
say mise-tree-swap 'mv ~/.local/share/mise ~/.local/share/mise.aside'
say mise-state 'touch ~/.local/state/mise/added'
say mise-config 'echo "[hooks]" >>~/.config/mise/config.toml'
say mise-config-new 'touch ~/.config/mise/conf.toml'
say config-swap 'mv ~/.config ~/.config.aside'
say share-swap 'mv ~/.local/share ~/.local/share.aside'
# The CLI's own settings.
say settings-write 'echo "{\"hooks\":{}}" >~/.claude/settings.json'
say settings-replace 'echo "{\"hooks\":{}}" >~/.claude/settings.next && mv ~/.claude/settings.next ~/.claude/settings.json'
say settings-remove 'rm -f ~/.claude/settings.json && ! test -e ~/.claude/settings.json'
say claude-swap 'mv ~/.claude ~/.claude.aside'
# What a CLI writes as it runs.
say sign-in-read 'grep -q $MARK ~/.claude/.credentials.json'
say sign-in-refresh 'echo refreshed >~/.claude/.credentials.next && mv ~/.claude/.credentials.next ~/.claude/.credentials.probe'
say share-write 'mkdir -p ~/.local/share/probe && touch ~/.local/share/probe/data'
say state-write 'mkdir -p ~/.local/state/probe && touch ~/.local/state/probe/data'
say muse-settings 'echo "{}" >~/.config/muse/settings.json'
say own-folders 'mkdir -p ~/.grok ~/.codex ~/.gemini-agentv/.gemini && echo x >~/.grok/config.toml && echo x >~/.gemini-agentv/.gemini/settings.json'
say build-write 'mkdir -p $DIR/work && touch $DIR/work/made'

# The app's own worker, as the contract tests start it: in the sandbox
# every app's worker starts in (daemon/apps/loader.ts).
mkdir -p $DIR/work/fixtures/pages
cp -r /usr/share/agentv/builder/recipes/streaming/template/app $DIR/work/app
echo $MARK >$DIR/work/fixtures/pages/page.html
mapfile -t jail < <(node --disable-warning=ExperimentalWarning --input-type=module -e "const { workerJail, systemPaths } = await import('/usr/share/agentv/daemon/apps/loader.ts'); const { realpathSync } = await import('node:fs'); console.log(['bwrap', ...workerJail({ dir: '$DIR/work/app', node: realpathSync(process.execPath), read: [], system: systemPaths() })].join('\n'))")
[ "\${#jail[@]}" -gt 1 ] || jail=(false)
printf '%s\n' "\${jail[@]}" >$DIR/jail.txt
"\${jail[@]}" true >>$DIR/jail.txt 2>&1
say jail '"\${jail[@]}" true'
say jail-app '"\${jail[@]}" cat $DIR/work/app/manifest.json'
say jail-app-write '"\${jail[@]}" touch $DIR/work/app/added'
say jail-sign-in '"\${jail[@]}" cat $HOME_DIR/.claude/.credentials.json'
say jail-cli '"\${jail[@]}" test -e $HOME_DIR/.local/bin/claude'
say jail-home '"\${jail[@]}" test -e $HOME_DIR'
say jail-page '"\${jail[@]}" cat $DIR/work/fixtures/pages/page.html'
say jail-way-out '"\${jail[@]}" ls /run/agentv-build-net'
node --disable-warning=ExperimentalWarning --input-type=module -e "const { forward } = await import('/usr/share/agentv/builder/sandbox/start.ts'); await forward(8080, '/run/agentv-build-net/proxy.sock'); await new Promise(() => {});" &
forwarder=\$!
sleep 1
say filter-outside 'curl -s -o /dev/null --max-time 10 -x http://127.0.0.1:8080 https://registry.npmjs.org/ || [ \$? -ne 7 ]'
say jail-filter '"\${jail[@]}" curl -s -o /dev/null --max-time 10 -x http://127.0.0.1:8080 https://registry.npmjs.org/ || [ \$? -ne 7 ]'
kill \$forwarder
node --disable-warning=ExperimentalWarning --input-type=module -e "
const { AppHost } = await import('/usr/share/agentv/daemon/apps/loader.ts');
const { readFileSync } = await import('node:fs');
const app = '$DIR/work/app';
const host = new AppHost({ dir: app, manifest: JSON.parse(readFileSync(app + '/manifest.json', 'utf8')) });
try { await host.start(); console.log('started'); } catch (error) { console.log('failed: ' + error.message); }
host.stop();
" >$DIR/worker.txt 2>&1
say worker 'grep -qx started $DIR/worker.txt'
echo done >>"\$out"
PROBE

# The daemon's ask, as root's hand-over takes it.
ssh_guest "sudo install -d -m 700 /var/lib/agentv/daemon/build-drop && printf '%s' '{\"build\":\"b1\",\"id\":\"local.home\",\"version\":\"1.0.0\",\"sentence\":\"a probe\",\"phase\":\"build\",\"recipe\":\"game\",\"provider\":\"claude\",\"path\":\"key\",\"safeguards\":true}' | sudo tee /var/lib/agentv/daemon/build-drop/start.json >/dev/null"

started=$SECONDS
while (( SECONDS - started < 240 )); do
  ssh_guest "sudo grep -q '^done' $DIR/probe.out" 2>/dev/null && break
  sleep 2
done
ssh_guest "cat /run/agentv-build/answer.json" >"$RUN_DIR/answer.json" 2>&1 || true
ssh_guest "sudo cat $DIR/probe.out" >"$RUN_DIR/probe.txt" 2>&1 || true
ssh_guest "sudo cat $DIR/jail.txt $DIR/worker.txt" >"$RUN_DIR/jail.txt" 2>&1 || true
ssh_guest "sudo journalctl -b -u agentv-build.service -u agentv-build-net.service -u '$UNIT' --no-pager" >"$RUN_DIR/builder.log" 2>&1 || true
ssh_guest "sudo find $HOME_DIR -maxdepth 3 -printf '%p %u:%g:%m\n'" >"$RUN_DIR/home-after.txt" 2>&1 || true

said() { grep -qx "$1 $2" "$RUN_DIR/probe.txt"; }
check "root's hand-over took the ask and started the build's sandbox" jq -e '.build == "b1" and .started == true' "$RUN_DIR/answer.json"
check "the probe ran as agentv-builder" said yes user
check "a build runs the provider's CLI from its home" said yes cli-runs
check "H3 a build can't change the CLI" said no cli-write
check "H3 or remove it" said no cli-remove
check "H3 or put another beside it" said no cli-new
check "H3 or move its folder aside" said no cli-swap
check "H3 or the folder above it" said no local-swap
check "H3 or make a folder beside them" said no local-new
check "H3 a build can't write into mise's tree" said no mise-tree
check "H3 or move it aside" said no mise-tree-swap
check "H3 or write mise's state" said no mise-state
check "H3 a build can't change mise's config" said no mise-config
check "H3 or add one" said no mise-config-new
check "H3 or move the config's folder aside" said no config-swap
check "H3 or the folder mise's tree is in" said no share-swap
check "H3 a build can't write the CLI's own settings" said no settings-write
check "H3 or put another file in their place" said no settings-replace
check "H3 or remove them" said no settings-remove
check "H3 or move their folder aside" said no claude-swap
check "the CLI on the box is the one that was fetched" ssh_guest "sudo grep -q '$MARK' $HOME_DIR/.local/bin/claude && sudo grep -q '$MARK' $HOME_DIR/.config/mise/config.toml && test \"\$(sudo cat $HOME_DIR/.claude/settings.json)\" = '{}'"
check "on a plan, the CLI in a build reads the plan's sign-in, as it must" said yes sign-in-read
check "and writes it again when it refreshes" said yes sign-in-refresh
check "a CLI still writes its own data" said yes share-write
check "and its state" said yes state-write
check "the builder still writes muse's settings for a step" said yes muse-settings
check "and each CLI's own folder" said yes own-folders
check "a build still writes its own folder" said yes build-write

check "H3 bubblewrap starts for the app's worker, in the build's sandbox" said yes jail
check "H3 the worker sees its own package" said yes jail-app
check "H3 and can't write it" said no jail-app-write
check "H3 the plan's sign-in isn't there to it" said no jail-sign-in
check "H3 nor the CLI" said no jail-cli
check "H3 the builder's home isn't there to it at all" said no jail-home
check "H3 nor a page the build saved" said no jail-page
check "H3 nor the build's way out" said no jail-way-out
check "the build itself reaches its filter" said yes filter-outside
check "H3 and the worker has no network, not even the filter" said no jail-filter
check "H3 the real worker starts under it and says it's ready" said yes worker

ssh_guest "sudo rm -rf /var/lib/agentv/build/local.home '/run/systemd/system/$UNIT.d' /usr/local/share/agentv-home-probe.sh $HOME_DIR/.claude/.credentials.json $HOME_DIR/.claude/.credentials.probe; sudo systemctl daemon-reload" || true

stop_vm
finish
