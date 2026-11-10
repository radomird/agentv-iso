#!/bin/bash
#
# What an installed box listens on, and what its firewall lets in (T15.2,
# ADR-085). The security review of 2026-11-10 could only read the code, so
# this asks the box itself: ss for every listening socket, IPv4 and IPv6,
# and ufw for its rules.
#
# Off the box's own loopback, only these may listen:
# - the phone companion, the daemon's port 3001;
# - the captive setup page, the daemon's port 3002, which answers only on
#   the setup hotspot's address;
# - Avahi, which the TV finds the home's servers with, and the name
#   lookups of systemd-resolved and the TV's own Chromium;
# - NetworkManager's DHCP clients;
# - the daemon's look for servers, UDP 3006 to 3009, only while it looks;
# - sshd, which this test's own harness turns on to reach the VM. A box
#   has it off (NUC-CHECKS has the check on a real one).
# The TV's pages (3000) and home's proxy (3005) are on loopback alone.
# Nothing listens for printing (631) or LocalSend (53317), and Docker's
# socket isn't there: first boot turned all three off (ADR-085).
#
# Then the same with the setup hotspot open, on a simulated radio: dnsmasq
# is added, on the hotspot's own device and address, and nothing else.
#
# The whole of ss, ufw and the enabled units goes in the run's folder
# either way, so a run shows what's really there.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-t15-listeners-ssh-timeout || exit 1
passwordless_sudo
wait_tv 240 >/dev/null || true

# The hotspot's device, once it's open. Empty while it's closed.
HOTSPOT_IF=""

# listeners <name>: every listening TCP socket and every UDP socket that
# isn't connected, with the process that holds it, kept as <name>.txt.
listeners() {
  ssh_sudo "ss -H -lntup" >"$RUN_DIR/$1.txt" 2>"$RUN_DIR/$1.err" || true
  log "What listens ($1):"
  cat "$RUN_DIR/$1.txt"
}

# rows <file>: a line per socket: protocol, address, port, process.
# ss prints the local address as address:port, with a %device after the
# address when the socket is tied to one, and [..] around an IPv6 address.
rows() {
  awk '{
    local = $5
    port = local; sub(/.*:/, "", port)
    addr = local; sub(/:[^:]*$/, "", addr)
    name = "-"
    if (match($0, /users:\(\("[^"]*"/)) name = substr($0, RSTART + 9, RLENGTH - 10)
    print $1, addr, port, name
  }' "$1"
}

# Loopback: 127.0.0.0/8 and ::1, with or without a device after it.
loopback() {
  local addr=${1%%%*}
  [[ $addr == 127.* || $addr == "[::1]" || $addr == "::1" ]]
}

# allowed <protocol> <address> <port> <process>: what may listen off
# loopback. From the first run on a box (2026-11-10): the daemon's two
# ports, Avahi, the harness's sshd, and the DNS stub Omarchy sets up for
# Docker's containers.
allowed() {
  local proto=$1 addr=$2 port=$3 name=$4
  # ss names a process by its main thread, and Node's is "node-MainThread".
  [[ $name == node* ]] && name=node
  case "$proto $port $name" in
    "tcp 3001 node" | "tcp 3002 node") return 0 ;; # the daemon: phones, and the captive page
    "tcp 22 sshd") return 0 ;; # this test's harness
    "udp 3006 node" | "udp 3007 node" | "udp 3008 node" | "udp 3009 node") return 0 ;; # a look for servers
    "udp 5353 avahi-daemon") return 0 ;;
  esac
  # Omarchy has systemd-resolved answer on Docker's bridge address too, for
  # containers. With Docker off no device has that address, so nothing
  # reaches it. It's Omarchy's file, so it stays.
  [[ $port == 53 && $addr == "172.17.0.1" && $name == systemd-resolve* ]] && return 0
  # The clock's own question to a time server: systemd-timesyncd opens a UDP
  # socket on a port of the moment while it asks, and closes it. It's a
  # client's socket, seen now and then, not something that listens.
  [[ $proto == "udp" && $name == systemd-timesyn* ]] && (( port >= 32768 )) && return 0
  # With the hotspot open: dnsmasq, on the hotspot's address and device only.
  if [[ -n $HOTSPOT_IF && $name == "dnsmasq" ]]; then
    [[ $port == 53 && $addr == "10.42.0.1" ]] && return 0
    [[ $proto == "udp" && $port == 67 && $addr == *"%$HOTSPOT_IF" ]] && return 0
  fi
  return 1
}

# outside <file>: the sockets off loopback that nothing above allows.
outside() {
  local proto addr port name
  while read -r proto addr port name; do
    loopback "$addr" && continue
    allowed "$proto" "$addr" "$port" "$name" || echo "$proto $addr:$port $name"
  done < <(rows "$1")
}

nothing_outside() {
  outside "$RUN_DIR/$1.txt" >"$RUN_DIR/$1-outside.txt"
  # Said here, so a failed run's log names what was outside the list.
  [[ ! -s $RUN_DIR/$1-outside.txt ]] || sed 's/^/outside the list: /' "$RUN_DIR/$1-outside.txt"
  if [[ -s $RUN_DIR/$1-outside.txt ]]; then
    log "Listening off loopback, and not on the list ($1):"
    cat "$RUN_DIR/$1-outside.txt"
  fi
  [[ -s $RUN_DIR/$1.txt && ! -s $RUN_DIR/$1-outside.txt ]]
}

# on_port <file> <port>: the rows for a port, any protocol.
on_port() {
  rows "$1" | awk -v port="$2" '$3 == port'
}

only_loopback() {
  local rows_for
  rows_for=$(on_port "$RUN_DIR/$1.txt" "$2")
  [[ -n $rows_for ]] && ! awk '$2 !~ /^127\./ && $2 != "[::1]" { found = 1 } END { exit !found }' <<<"$rows_for"
}

listens() {
  [[ -n $(on_port "$RUN_DIR/$1.txt" "$2") ]]
}

# --- With the hotspot closed, as a box on a cable is ----------------------

listeners all
ssh_sudo "systemctl list-unit-files --state=enabled --no-pager" >"$RUN_DIR/enabled-units.txt" 2>&1 || true
ssh_sudo "ufw status verbose" >"$RUN_DIR/ufw.txt" 2>&1 || true
ssh_sudo "iptables -S; ip6tables -S" >"$RUN_DIR/iptables.txt" 2>&1 || true
log "The firewall:"
cat "$RUN_DIR/ufw.txt"

check "T15.2 ss lists the box's sockets" test -s "$RUN_DIR/all.txt"
check "T15.2 nothing outside the list listens off loopback, on IPv4 or IPv6" nothing_outside all
check "T15.2 the phone companion listens on 3001" listens all 3001
check "T15.2 the captive page's port, 3002, is the daemon's" listens all 3002
check "T15.2 the TV's pages, port 3000, are on loopback alone" only_loopback all 3000
check "T15.2 home's proxy, port 3005, is on loopback alone" only_loopback all 3005
silent() {
  [[ -s $RUN_DIR/$1.txt && -z $(on_port "$RUN_DIR/$1.txt" "$2") ]]
}
check "ADR-085 nothing listens for printing (631), on any address" silent all 631
check "ADR-085 nothing listens on LocalSend's port (53317)" silent all 53317
# sshd is the harness's: the only port 22 here is the one it opened.
sshd_only() {
  ! on_port "$RUN_DIR/all.txt" 22 | awk '$4 != "sshd" { found = 1 } END { exit !found }'
}
check "T15.2 port 22 is only this test's own sshd" sshd_only

# First boot turned them off: still installed, as Omarchy brings them, and
# neither enabled nor running. That's the "before and after": Omarchy's
# install enables docker.socket and cups.service (install/config/
# enable-services.sh), and the harness has no look at the box before
# AgenTV's first boot.
unit_off() {
  local enabled active
  enabled=$(ssh_guest "systemctl is-enabled $1" 2>/dev/null || true)
  active=$(ssh_guest "systemctl is-active $1" 2>/dev/null || true)
  echo "$1 $enabled $active" >>"$RUN_DIR/units-off.txt"
  [[ $enabled == "disabled" && $active != "active" ]]
}
check "ADR-085 Docker is still installed" ssh_guest "pacman -Q docker"
check "ADR-085 its socket is off: disabled, and not waiting" unit_off docker.socket
check "ADR-085 and so is its service" unit_off docker.service
check "ADR-085 there's no Docker socket to ask" ssh_guest "! test -e /run/docker.sock && ! test -e /var/run/docker.sock"
check "ADR-085 CUPS is still installed" ssh_guest "pacman -Q cups"
check "ADR-085 printing is off: cups.service" unit_off cups.service
check "ADR-085 and cups.socket" unit_off cups.socket
check "ADR-085 and cups.path" unit_off cups.path
not_masked() {
  ! ssh_guest "systemctl is-enabled docker.socket docker.service cups.service cups.socket cups.path" 2>/dev/null | grep -q masked
}
check "ADR-085 none of them is masked, so systemctl enable --now brings one back" not_masked
check "ADR-085 Avahi stays on, for finding servers" ssh_guest "systemctl is-active avahi-daemon.service"
log "The units first boot turned off (unit, enabled, active):"
cat "$RUN_DIR/units-off.txt" 2>/dev/null || true
# A box installed from this ISO gets it at first boot. One that came from
# an older release and was updated gets it from a migration.
said_so() {
  ssh_sudo "grep -q 'install/tv/services.sh' /var/log/agentv-firstboot.log" ||
    ssh_guest "grep -ls 'install/tv/services.sh' /usr/share/agentv/migrations/*.sh | while read -r file; do test -f ~/.local/state/agentv/migrations/\${file##*/} || exit 1; done"
}
check "ADR-085 first boot's log says it turned them off, or the box's migration ran" said_so

# The firewall: nothing in by default, the phone companion from the home
# network's private ranges only, and no rule for LocalSend. The one rule
# for port 22 is the harness's own, for QEMU's host address.
check "T15.2 the firewall is on" grep -q "^Status: active" "$RUN_DIR/ufw.txt"
check "T15.2 it lets nothing in by default" grep -Eq "^Default: deny \(incoming\)" "$RUN_DIR/ufw.txt"
phone_rules() {
  local got want
  got=$(awk '$1 == "3001/tcp" { for (i = 2; i <= NF; i++) if ($i == "IN") { print $(i + 1); break } }' "$RUN_DIR/ufw.txt" | sort | paste -sd ' ')
  want=$(printf '%s\n' 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7 fe80::/10 | sort | paste -sd ' ')
  echo "$got" >"$RUN_DIR/ufw-3001.txt"
  [[ $got == "$want" ]]
}
check "T15.2 port 3001 is open to the home network's private ranges, and to nothing else" phone_rules
without() {
  [[ -s $2 ]] && ! grep -q -- "$1" "$2"
}
check "ADR-085 the firewall has no rule for LocalSend's port" without 53317 "$RUN_DIR/ufw.txt"
check "ADR-085 nor do the kernel's own tables" without 53317 "$RUN_DIR/iptables.txt"
# Port 22 is the harness's: the test ISO's unattended install turns sshd on
# and opens the port, and the test adds a rule for QEMU's host. A box
# installed from the USB stick has neither (NUC-CHECKS.md).
ssh_rules() {
  # No rule for port 22 names any address but QEMU's host or every address.
  ! grep -E '^(22(/tcp)?|SSH|OpenSSH)[[:space:]]' "$RUN_DIR/ufw.txt" | grep -Ev '10\.0\.2\.2|Anywhere' | grep -q .
}
check "T15.2 the only rules for port 22 are this test's own" ssh_rules
# ufw writes "Anywhere" for a rule with no "from". Apart from the harness's
# port 22, no rule that lets something in has one.
from_anywhere() {
  grep -Ev '^(22(/tcp)?|SSH|OpenSSH)[[:space:]]' "$RUN_DIR/ufw.txt" |
    awk '/ALLOW IN/ { for (i = 1; i <= NF; i++) if ($i == "IN" && $(i + 1) ~ /^Anywhere/) found = 1 } END { exit !found }'
}
no_open_rule() {
  [[ -s $RUN_DIR/ufw.txt ]] && ! from_anywhere
}
check "T15.2 no rule lets a port in from every address" no_open_rule

# --- With the setup hotspot open -------------------------------------------
# The VM has no Wi-Fi card, so the box gets one of the kernel's simulated
# radios, as the hotspot's own check does.

check "the VM gets a simulated Wi-Fi radio" ssh_sudo "modprobe mac80211_hwsim radios=1"
for _ in $(seq 1 30); do
  ssh_guest "nmcli -t -f TYPE device status | grep -qx wifi" && break
  sleep 1
done
box_if=$(ssh_guest "nmcli -t -f DEVICE,TYPE device status | awk -F: '\$2 == \"wifi\" { print \$1; exit }'" 2>/dev/null || true)
check "and NetworkManager takes it" test -n "$box_if"

guest "agentv hotspot start" >"$RUN_DIR/hotspot-start.txt" 2>&1 || true
cat "$RUN_DIR/hotspot-start.txt"
hotspot_on() {
  local _
  for _ in $(seq 1 30); do
    ssh_guest "jq -e '.on == true' /run/agentv-hotspot/state.json" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
before=$FAILURES
check "the setup hotspot opens" hotspot_on
if (( FAILURES > before )); then
  log "The hotspot didn't open in the VM, so what listens with it open wasn't read. That's NUC-CHECKS' port scan with the hotspot on."
else
  # dnsmasq starts right after the state says on.
  for _ in $(seq 1 20); do
    ssh_guest "pgrep -x dnsmasq" >/dev/null 2>&1 && break
    sleep 1
  done
  sleep 2
  HOTSPOT_IF=$box_if
  listeners hotspot
  ssh_sudo "iptables -S; iptables -t nat -S" >"$RUN_DIR/hotspot-iptables.txt" 2>&1 || true

  check "T15.2 with the hotspot open, still nothing outside the list listens off loopback" nothing_outside hotspot
  dns_on_hotspot() {
    local rows_for
    rows_for=$(on_port "$RUN_DIR/hotspot.txt" 53 | awk '$4 == "dnsmasq"')
    [[ -n $rows_for ]] && ! awk '$2 != "10.42.0.1" { found = 1 } END { exit !found }' <<<"$rows_for"
  }
  check "T15.2 the hotspot's DNS answers on the hotspot's address alone" dns_on_hotspot
  dhcp_on_hotspot() {
    local rows_for
    rows_for=$(on_port "$RUN_DIR/hotspot.txt" 67)
    [[ -n $rows_for ]] && ! awk -v dev="%$HOTSPOT_IF" '$4 != "dnsmasq" || index($2, dev) == 0 { found = 1 } END { exit !found }' <<<"$rows_for"
  }
  check "T15.2 its DHCP is tied to the hotspot's device" dhcp_on_hotspot
  check "T15.2 the TV's pages are still on loopback alone" only_loopback hotspot 3000
  # The holes in the firewall are for the hotspot's device, each of them.
  holes_on_device() {
    local holes
    holes=$(grep "agentv-setup-hotspot" "$RUN_DIR/hotspot-iptables.txt")
    [[ -n $holes ]] && ! grep -v -- "-i $HOTSPOT_IF " <<<"$holes" | grep -q .
  }
  check "T15.2 every hole the hotspot makes in the firewall is on its own device" holes_on_device
  check "T15.2 port 80 goes to the captive page, from the hotspot's device only" \
    grep -q -- "-A PREROUTING -i $HOTSPOT_IF -p tcp .*--dport 80 .*-j REDIRECT --to-ports 3002" "$RUN_DIR/hotspot-iptables.txt"
  # From the box's cabled address, the captive page says nothing: it
  # answers only where the socket's own address is the hotspot's.
  wired=$(ssh_guest "ip -4 -o addr show scope global | awk '\$2 != \"$HOTSPOT_IF\" { sub(/\\/.*/, \"\", \$4); print \$4; exit }'" 2>/dev/null || true)
  wired_closed() {
    [[ -n $wired ]] || return 1
    local code
    code=$(ssh_guest "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://$wired:3002/" 2>/dev/null || true)
    echo "$wired $code" >"$RUN_DIR/captive-wired.txt"
    [[ $code != 200 ]]
  }
  check "T15.2 the captive page gives nothing on the cabled address (${wired:-no address})" wired_closed
  on_hotspot() {
    [[ $(ssh_guest "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://10.42.0.1:3002/" 2>/dev/null) == 200 ]]
  }
  check "T15.2 and its page on the hotspot's own" on_hotspot

  guest "agentv hotspot stop" >"$RUN_DIR/hotspot-stop.txt" 2>&1 || true
  for _ in $(seq 1 20); do
    ssh_guest "pgrep -x dnsmasq" >/dev/null 2>&1 || break
    sleep 1
  done
  HOTSPOT_IF=""
  listeners closed
  ssh_sudo "iptables -S; iptables -t nat -S" >"$RUN_DIR/closed-iptables.txt" 2>&1 || true
  check "T15.2 with the hotspot closed again, dnsmasq is gone" without dnsmasq "$RUN_DIR/closed.txt"
  check "T15.2 and nothing outside the list listens off loopback" nothing_outside closed
  check "T15.2 and its holes in the firewall are gone" without agentv-setup-hotspot "$RUN_DIR/closed-iptables.txt"
fi

stop_vm
finish
