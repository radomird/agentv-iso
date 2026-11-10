#!/bin/bash
#
# An app's worker on an installed box: the daemon starts each app's code in
# a sandbox of its own, with its own user and network namespaces, no network
# device but its loopback, and a root that holds Node, the system's files
# and the app's own package, and nothing of the TV's sign-ins, its keys or
# the person's home. The check asks the built-in Weather for a tile, which
# starts its worker the way every app's is started, and reads what that
# worker is from /proc. It also checks home's Chromium keeps WebRTC inside
# its filter.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-app-sandbox-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-app-sandbox-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

# A mark where the sign-ins are, which anyone on the box could read.
MARK="agentv-probe-$RANDOM$RANDOM"
ssh_guest "sudo install -d -m 755 /var/lib/agentv/chromium && echo $MARK | sudo tee /var/lib/agentv/chromium/$MARK >/dev/null && sudo chmod 644 /var/lib/agentv/chromium/$MARK"

tile() {
  ssh_guest "curl -fsS --max-time 15 http://127.0.0.1:3000/api/tile/agentv.$1/s" 2>/dev/null || true
}

# Weather's worker: the Node that runs worker.ts for its package. Bubblewrap
# has the same words on its own command line, so the name decides.
worker_pid() {
  ssh_guest "for pid in \$(pgrep -f 'daemon/apps/worker.ts .*agentv.weather' || true); do case \"\$(cat /proc/\$pid/comm 2>/dev/null)\" in node* | MainThread) echo \$pid ;; esac; done | tail -n 1"
}

tile weather >"$RUN_DIR/weather-s.json"
tile clock >"$RUN_DIR/clock-s.json"
check "the weather tile answers, from its worker" jq -e '.tile.headline.label' "$RUN_DIR/weather-s.json"

pid=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pid=$(worker_pid)
  [[ -n $pid ]] && break
  tile weather >/dev/null
  sleep 2
done
ssh_guest "ps -eo pid,ppid,user,comm,args | grep -E 'bwrap|worker.ts' | grep -v grep" >"$RUN_DIR/workers.txt" 2>&1 || true
check "Weather's worker is running" test -n "$pid"

if [[ -n $pid ]]; then
  ns() { ssh_guest "sudo readlink /proc/$1/ns/$2" 2>/dev/null; }
  inside() { ssh_guest "sudo $1 /proc/$pid/root$2" >/dev/null 2>&1; }
  {
    for kind in user net mnt pid ipc; do echo "$kind: worker $(ns "$pid" "$kind"), the box $(ns 1 "$kind")"; done
    ssh_guest "sudo ls -la /proc/$pid/root/ /proc/$pid/root/etc /proc/$pid/root/var 2>&1"
    ssh_guest "sudo nsenter -t $pid -n ip -o link 2>&1"
    ssh_guest "sudo cat /proc/$pid/status | grep -E '^(Uid|Gid|CapEff|NoNewPrivs|Seccomp)'"
  } >"$RUN_DIR/worker.txt" 2>&1 || true

  differs() { local a b; a=$(ns "$pid" "$1"); b=$(ns 1 "$1"); [[ -n $a && -n $b && $a != "$b" ]]; }
  check "it's started by bubblewrap" grep -Eq "[[:space:]]bwrap[[:space:]].*--unshare-all .*worker.ts" "$RUN_DIR/workers.txt"
  check "it's in a user namespace of its own" differs user
  check "it's in a network namespace of its own" differs net
  check "it's in a mount namespace of its own" differs mnt
  check "it's in a process namespace of its own" differs pid
  only_loopback() { [[ $(ssh_guest "sudo nsenter -t $pid -n ip -o link" | awk -F': ' '{print $2}' | paste -sd,) == lo ]]; }
  check "its only network device is its own loopback" only_loopback
  no_route() { [[ -z $(ssh_guest "sudo nsenter -t $pid -n ip route" 2>/dev/null) ]]; }
  check "it has no route anywhere" no_route
  check "it has no capabilities" ssh_guest "sudo grep -Eq '^CapEff:[[:space:]]+0+$' /proc/$pid/status"

  check "the mark is where the TV's sign-ins are, on the box" ssh_guest "cat /var/lib/agentv/chromium/$MARK"
  not_inside() { ! inside "test -e" "$1"; }
  check "it sees Node and the system's files" inside "test -x" /usr/bin/node
  check "it sees its own package" inside "test -f" /usr/share/agentv/apps/builtin/agentv.weather/manifest.json
  check "it can't see the TV's sign-ins" not_inside /var/lib/agentv/chromium
  check "it can't see anything of /var/lib/agentv" not_inside /var/lib/agentv
  check "it can't see the box's keys" not_inside /etc/agentv
  check "it can't see anyone's home" not_inside /home
  check "it can't see root's home" not_inside /root
  check "it has no /proc" not_inside /proc/1
  check "it can't see the daemon's sockets in /run" not_inside /run
  read_only() { ! ssh_guest "sudo nsenter -t $pid -m -U --preserve-credentials touch /usr/share/agentv/apps/builtin/agentv.weather/$MARK" >/dev/null 2>&1; }
  check "its package is read-only to it" read_only
fi

# The daemon has an account of its own now, and its state is only its own.
for folder in daemon backgrounds shared; do
  check "/var/lib/agentv/$folder is the daemon's alone" \
    test "$(ssh_guest "sudo stat -c '%U %a %F' /var/lib/agentv/$folder" 2>/dev/null)" = "agentv-server 700 directory"
done

# Stopping the daemon takes its workers with it.
ssh_guest "journalctl -b --no-pager -u agentv-daemon" >"$RUN_DIR/daemon.log" 2>&1 || true
# Said here, so a failed run's log has bubblewrap's own reason.
grep -m 5 "sandbox didn't start" "$RUN_DIR/daemon.log" | sed 's/^/the daemon said: /' || true
check "no app was refused for want of a sandbox" bash -c "! grep -q \"sandbox didn't start\" '$RUN_DIR/daemon.log'"
ssh_guest "sudo systemctl stop agentv-daemon" >/dev/null 2>&1 || true
sleep 2
gone() { [[ -z $(worker_pid) ]]; }
check "its worker goes when the daemon does" gone
ssh_guest "sudo systemctl start agentv-daemon" >/dev/null 2>&1 || true

# Home's Chromium: a page app's WebRTC opens no connection of its own.
ssh_guest "ps -eo args | grep -- '--user-data-dir=/var/lib/agentv/chromium-home' | grep -v -- '--type=' | grep -v grep | head -n 1" >"$RUN_DIR/home-chromium.txt" 2>&1 || true
check "home's Chromium goes out through the filter" grep -q -- "--proxy-server=http://127.0.0.1:3005" "$RUN_DIR/home-chromium.txt"
check "home's Chromium keeps WebRTC inside the filter" grep -q -- "--webrtc-ip-handling-policy=disable_non_proxied_udp" "$RUN_DIR/home-chromium.txt"
check "under the switch's older name too" grep -q -- "--force-webrtc-ip-handling-policy=disable_non_proxied_udp" "$RUN_DIR/home-chromium.txt"
ssh_guest "chromium --version" >"$RUN_DIR/chromium-version.txt" 2>&1 || true
ssh_guest "node --version; bwrap --version" >"$RUN_DIR/versions.txt" 2>&1 || true

stop_vm
finish
