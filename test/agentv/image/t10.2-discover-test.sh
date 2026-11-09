#!/bin/bash
#
# The servers and shares on your network (T10.2), on an installed box. A
# network namespace on the box stands in for the home network, through a
# veth pair: the box is 192.168.77.1 on lan0, and two machines sit behind
# it. 192.168.77.10 is a NAS that answers Jellyfin's discovery on UDP 7359,
# announces a Samba share over mDNS as nas.local, and runs Immich on 2283.
# 192.168.77.20 announces nothing and runs an Immich too. The daemon's list
# has the Jellyfin, the share and the Immich on the NAS, by their own
# answers, through the box's own firewall and Avahi. Counters in the
# namespace show that the box only asked the NAS's Immich, and never the
# quiet machine or any other port.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-T10.2-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-T10.2-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

# --- The home network's stand-ins ---------------------------------------------

ssh_guest "mkdir -p /tmp/agentv-discover && cat >/tmp/agentv-discover/standins.py" <<'PY'
# The NAS and the quiet machine, in their own network namespace. Every
# datagram and request each one gets goes in its log.
import http.server, json, socket, struct, sys, threading, time

NAS, QUIET = "192.168.77.10", "192.168.77.20"
log = open("/tmp/agentv-discover/standins.log", "a", buffering=1)

def say(line):
    log.write(f"{time.strftime('%H:%M:%S')} {line}\n")

# Jellyfin's discovery: the answer to "who is JellyfinServer?".
def jellyfin():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(("", 7359))
    while True:
        data, source = s.recvfrom(2048)
        say(f"udp 7359 from {source[0]}:{source[1]} {data[:40]!r}")
        if data == b"who is JellyfinServer?":
            s.sendto(json.dumps({"Address": f"http://{NAS}:8096", "Id": "a5b0c6d1e2f34a5b8c9d0e1f2a3b4c5d", "Name": "living room", "EndpointAddress": None}).encode(), source)

# mDNS: a Samba share, "living room nas", on nas.local, announced every
# second and whenever someone asks, the way Avahi on a NAS does.
def name(text):
    return b"".join(bytes([len(part.encode())]) + part.encode() for part in text.split(".")) + b"\0"

def record(owner, kind, klass, ttl, data):
    return name(owner) + struct.pack(">HHIH", kind, klass, ttl, len(data)) + data

def mdns():
    instance = "living room nas._smb._tcp.local"
    records = [
        record("_smb._tcp.local", 12, 1, 4500, name(instance)),
        record(instance, 33, 0x8001, 120, struct.pack(">HHH", 0, 0, 445) + name("nas.local")),
        record(instance, 16, 0x8001, 4500, b"\0"),
        record("nas.local", 1, 0x8001, 120, socket.inet_aton(NAS)),
    ]
    packet = struct.pack(">HHHHHH", 0, 0x8400, 0, len(records), 0, 0) + b"".join(records)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", 5353))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton("224.0.0.251") + socket.inet_aton(NAS))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(NAS))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    s.settimeout(1)
    while True:
        try:
            data, source = s.recvfrom(9000)
            if len(data) > 2 and not data[2] & 0x80:
                s.sendto(packet, ("224.0.0.251", 5353))
        except socket.timeout:
            s.sendto(packet, ("224.0.0.251", 5353))

# Immich's ping, on both machines.
def immich(address):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            say(f"http {address}:2283 {self.command} {self.path}")
            body = b'{"res":"pong"}' if self.path == "/api/server/ping" else b"{}"
            self.send_response(200 if self.path == "/api/server/ping" else 404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        do_POST = do_GET
        def log_message(self, *args):
            pass
    http.server.ThreadingHTTPServer((address, 2283), Handler).serve_forever()

for target, args in ((jellyfin, ()), (mdns, ()), (immich, (NAS,)), (immich, (QUIET,))):
    threading.Thread(target=target, args=args, daemon=True).start()
say("ready")
while True:
    time.sleep(60)
PY

# The namespace, its two machines, and counters for what reaches them: the
# NAS's Immich, any other connection, and any other datagram sent to one
# machine (not to everyone, as broadcasts and multicasts are).
ssh_sudo "
  set -e
  ip netns add agentv-lan
  ip link add lan0 type veth peer name eth0 netns agentv-lan
  ip addr add 192.168.77.1/24 dev lan0
  ip link set lan0 up
  ip -n agentv-lan addr add 192.168.77.10/24 dev eth0
  ip -n agentv-lan addr add 192.168.77.20/24 dev eth0
  ip -n agentv-lan link set lo up
  ip -n agentv-lan link set eth0 up
  ip netns exec agentv-lan iptables -A INPUT -p tcp --syn -d 192.168.77.10 --dport 2283 -m comment --comment nas-immich -j ACCEPT
  ip netns exec agentv-lan iptables -A INPUT -p tcp --syn -m comment --comment other-tcp -j ACCEPT
  ip netns exec agentv-lan iptables -A INPUT -p udp -d 192.168.77.10 ! --dport 5353 -m comment --comment nas-udp -j ACCEPT
  ip netns exec agentv-lan iptables -A INPUT -p udp -d 192.168.77.20 -m comment --comment quiet-udp -j ACCEPT
  ip netns exec agentv-lan setsid python3 /tmp/agentv-discover/standins.py </dev/null >/tmp/agentv-discover/standins.out 2>&1 &
" >"$RUN_DIR/t10.2-lan.log" 2>&1
standins_up() {
  local started=$SECONDS
  while (( SECONDS - started < 20 )); do
    ssh_guest "grep -q ready /tmp/agentv-discover/standins.log" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}
check "the home network's stand-ins are up" standins_up

# The counter on a rule in the namespace, by its comment.
counter() {
  ssh_sudo "ip netns exec agentv-lan iptables -L INPUT -v -n -x" 2>/dev/null | awk -v rule="/* $1 */" 'index($0, rule) { print $1 }'
}

# --- The list ---------------------------------------------------------------------

kinds="jellyfin,emby,plex,immich,smb,nfs"
discover() {
  ssh_guest "curl -fsS --max-time 5 'http://127.0.0.1:3000/api/discover?kinds=$kinds'" 2>/dev/null
}
until_found() {
  local started=$SECONDS
  while (( SECONDS - started < 40 )); do
    discover >"$RUN_DIR/t10.2-found.json" 2>/dev/null || true
    [[ $(jq -r "$1" "$RUN_DIR/t10.2-found.json" 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 1
}

check "the box starts looking when a list asks" until_found '.ok == true and .looking == true'
check "T10.2 the stand-in Jellyfin answering on 7359 is in the list, by the name it gave" \
  until_found '[.found[] | select(.kind == "jellyfin" and .name == "living room" and .url == "http://192.168.77.10:8096" and .via == "udp-7359")] | length == 1'
check "T10.2 the Samba share announced over mDNS is in the list, as nas.local" \
  until_found '[.found[] | select(.kind == "smb" and .name == "living room nas" and .url == "smb://nas.local/" and .host == "nas.local" and .via == "mdns")] | length == 1'
check "T10.2 the Immich on the machine that announced SMB is in the list" \
  until_found '[.found[] | select(.kind == "immich" and .url == "http://192.168.77.10:2283" and .host == "nas.local" and .via == "immich-ping")] | length == 1'
check "the Jellyfin found by its address takes the NAS's mDNS name" \
  until_found '[.found[] | select(.kind == "jellyfin" and .host == "nas.local")] | length == 1'
cp "$RUN_DIR/t10.2-found.json" "$RUN_DIR/t10.2-list.json" 2>/dev/null || true

# Long enough for every round of the look's questions to have gone.
sleep 25
ssh_guest "cat /tmp/agentv-discover/standins.log" >"$RUN_DIR/t10.2-standins.log" 2>&1 || true
ssh_sudo "ip netns exec agentv-lan iptables -L INPUT -v -n -x" >"$RUN_DIR/t10.2-counters.log" 2>&1 || true
nas_immich=$(counter nas-immich)
other_tcp=$(counter other-tcp)
nas_udp=$(counter nas-udp)
quiet_udp=$(counter quiet-udp)
echo "connections: nas immich $nas_immich, other $other_tcp; datagrams to one machine: nas $nas_udp, quiet $quiet_udp" | tee -a "$RUN_DIR/t10.2-counters.log"
# Immich's ping, once a look, and nothing else of the NAS's.
only_ping() {
  (( ${nas_immich:-0} >= 1 && ${nas_immich:-0} <= 2 )) || return 1
  ! grep ' http 192.168.77.10:2283 ' "$RUN_DIR/t10.2-standins.log" | grep -qv ' GET /api/server/ping$'
}
nothing_else() {
  [[ ${other_tcp:-x} == 0 && ${nas_udp:-x} == 0 && ${quiet_udp:-x} == 0 ]] || return 1
  ! grep -q ' http 192.168.77.20:' "$RUN_DIR/t10.2-standins.log"
}
check "T10.2 the NAS's Immich was asked at /api/server/ping, and only that" only_ping
check "T10.2 nothing else is probed: no other connection, and nothing sent to one machine alone" nothing_else

# With no list asking, the look ends after 45 s and the ports the answers
# come back to close.
look_over() {
  local started=$SECONDS
  while (( SECONDS - started < 70 )); do
    ssh_guest "ss -Hlun" 2>/dev/null | grep -Eq ':300[6-9][[:space:]]' || return 0
    sleep 5
  done
  return 1
}
check "nothing listens on the answers' ports once the look is over" look_over

ssh_sudo "ip netns pids agentv-lan | xargs -r kill; ip netns del agentv-lan" >/dev/null 2>&1 || true
stop_vm
finish
