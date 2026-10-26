#!/bin/bash
#
# The setup hotspot on an installed box (stage 4). The VM has no Wi-Fi card,
# so it gets three of the kernel's simulated radios (mac80211_hwsim): the
# box's own, a phone's and a home Wi-Fi's, the last two in network namespaces
# of their own, so what passes between them goes over the simulated air.
#
# On Ethernet, first boot leaves the hotspot closed. Opened from a terminal,
# the box's network comes up with the home Wi-Fi in its list, and the
# welcome screen shows its QR code. The phone joins with wpa_supplicant, gets
# an address and the captive page's address from dnsmasq, every name points
# at the box, and iOS's and Android's "am I online" pages land on the
# captive page. A wrong password for the home Wi-Fi opens the hotspot again
# with the reason. The right one joins it, and the hotspot, its firewall
# holes and its dnsmasq are gone, with the password in no log.

# shellcheck disable=SC2016 # the $names in jq's filters are jq's own

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

HOME_SSID=home-wifi-test
HOME_PASSWORD=home-pass-4826

start_vm_from_base
wait_for_ssh 300 failure-hotspot-ssh-timeout || exit 1
passwordless_sudo
wait_tv 240 >/dev/null || { capture_console "failure-hotspot-no-tv"; check "the TV session came up" false; stop_vm; finish; }

# First boot on Ethernet: the check ran and left the hotspot closed. The
# package enables it through /usr/lib's multi-user.target.wants, which
# systemctl is-enabled doesn't count, so this asks whether boot wanted it and
# whether it ran.
wanted_at_boot() {
  ssh_guest "systemctl list-dependencies --plain --no-pager multi-user.target" 2>/dev/null | grep -q "agentv-hotspot-boot.service"
}
check "the first-boot check is wanted at boot" wanted_at_boot
ran_at_boot() {
  [[ $(ssh_guest "systemctl show -p ExecMainStartTimestampMonotonic --value agentv-hotspot-boot.service" 2>/dev/null) =~ ^[1-9] ]] &&
    [[ $(ssh_guest "systemctl show -p ExecMainStatus --value agentv-hotspot-boot.service" 2>/dev/null) == "0" ]]
}
check "and it ran, and finished" ran_at_boot
check "its hand-over to root is waiting" ssh_guest "systemctl is-active agentv-hotspot.path"
closed() {
  [[ $(ssh_guest "systemctl is-active agentv-hotspot.service" 2>/dev/null) != "active" ]]
}
check "on Ethernet, the hotspot stays closed" closed

# The radios, and the phone and the home Wi-Fi in namespaces of their own.
check "the VM gets three simulated Wi-Fi radios" ssh_sudo "modprobe mac80211_hwsim radios=3"
for _ in $(seq 1 30); do
  (( $(ssh_guest "ls /sys/class/ieee80211 | wc -l" 2>/dev/null || echo 0) >= 3 )) && break
  sleep 1
done
mapfile -t phys < <(ssh_guest "ls /sys/class/ieee80211" 2>/dev/null | sort -V)
log "Radios: ${phys[*]}"
ssh_sudo "ip netns add phone && ip netns add home && iw phy ${phys[1]} set netns name phone && iw phy ${phys[2]} set netns name home" >"$RUN_DIR/netns.log" 2>&1 || true
phone_if=$(ssh_sudo "ip netns exec phone ls /sys/class/net | grep -vx lo | head -n 1" 2>/dev/null || true)
home_if=$(ssh_sudo "ip netns exec home ls /sys/class/net | grep -vx lo | head -n 1" 2>/dev/null || true)
check "the phone's and the home Wi-Fi's radios are in their own namespaces" test -n "$phone_if" -a -n "$home_if"
for _ in $(seq 1 30); do
  ssh_guest "nmcli -t -f TYPE device status | grep -qx wifi" && break
  sleep 1
done
box_if=$(ssh_guest "nmcli -t -f DEVICE,TYPE device status | awk -F: '\$2 == \"wifi\" { print \$1; exit }'" 2>/dev/null || true)
check "and the box keeps one for itself" test -n "$box_if"

# The home Wi-Fi: an access point with WPA2, and addresses from its own
# dnsmasq. Passwords go to the box through stdin, never on sudo's command
# line, which sudo writes to the journal.
private_file() {
  ssh_guest "sudo sh -c 'umask 077 && cat >$1'"
}
private_file /run/agentv-test-home.conf <<EOF
network={
  ssid="$HOME_SSID"
  mode=2
  frequency=2437
  key_mgmt=WPA-PSK
  proto=RSN
  pairwise=CCMP
  group=CCMP
  psk="$HOME_PASSWORD"
}
EOF
ssh_sudo "ip netns exec home ip link set lo up
ip netns exec home ip link set $home_if up
ip netns exec home wpa_supplicant -B -i $home_if -c /run/agentv-test-home.conf -P /run/agentv-test-home-wpa.pid
ip netns exec home ip addr add 192.168.77.1/24 dev $home_if
ip netns exec home dnsmasq --conf-file=/dev/null --port=0 --interface=$home_if --bind-interfaces \
  --dhcp-range=192.168.77.10,192.168.77.50,255.255.255.0,1h \
  --pid-file=/run/agentv-test-home-dnsmasq.pid --dhcp-leasefile=/run/agentv-test-home.leases" >"$RUN_DIR/home.log" 2>&1 || true
cat "$RUN_DIR/home.log"
home_up() {
  local _
  for _ in $(seq 1 20); do
    ssh_sudo "ip netns exec home iw dev $home_if info" 2>/dev/null | grep -q "type AP" && return 0
    sleep 1
  done
  return 1
}
check "the home Wi-Fi is up as an access point" home_up
# The box has to see it before it opens its own network, as a box that's
# setting up does.
box_sees_home() {
  local _
  for _ in $(seq 1 20); do
    ssh_sudo "nmcli -t -f SSID device wifi list --rescan yes ifname $box_if" 2>/dev/null | grep -qx "$HOME_SSID" && return 0
    sleep 2
  done
  return 1
}
check "the box can see it" box_sees_home

# The hotspot, opened from a terminal.
guest "agentv hotspot start" >"$RUN_DIR/start.txt" 2>&1 || true
cat "$RUN_DIR/start.txt"
state() {
  ssh_guest "cat /run/agentv-hotspot/state.json" 2>/dev/null || echo '{}'
}
on() {
  jq -e '.on == true' <<<"$(state)" >/dev/null
}
check "agentv hotspot start opens it" on
ssid=$(jq -r '.ssid // empty' <<<"$(state)")
password=$(jq -r '.password // empty' <<<"$(state)")
log "The hotspot: $ssid"
ap_mode() {
  ssh_guest "iw dev $box_if info" 2>/dev/null | grep -q "type AP"
}
check "the box's radio is an access point" ap_mode
saw_home() {
  ssh_guest "jq -e 'map(.ssid) | index(\"$HOME_SSID\") != null' /run/agentv-hotspot/networks.json" >/dev/null 2>&1
}
before=$FAILURES
check "it saw the home Wi-Fi before it opened" saw_home
(( FAILURES == before )) || ssh_guest "cat /run/agentv-hotspot/networks.json"
holes() {
  ssh_sudo "iptables -S; iptables -t nat -S" 2>/dev/null | grep -c "agentv-setup-hotspot" || true
}
check "the firewall has its five holes, on its own interface" bash -c "[[ $(holes) == 5 ]]"
ssh_sudo "iptables -t nat -S PREROUTING" >"$RUN_DIR/nat.txt" 2>&1 || true
check "port 80 goes to the captive page" grep -q -- "-i $box_if -p tcp -m tcp --dport 80 .*agentv-setup-hotspot.* -j REDIRECT --to-ports 3002" "$RUN_DIR/nat.txt"

# The welcome screen shows its QR code.
check "the welcome screen says to scan it (OCR)" ocr_finds welcome "scan this" 15
capture_console "success-hotspot-welcome"
qr() {
  ssh_guest "curl -fsS http://127.0.0.1:3000/api/hotspot/qr" 2>/dev/null | grep -q "<svg"
}
check "with the hotspot's QR code" qr

# The phone joins it.
ssh_guest "cat >/tmp/agentv-phone.py" <"$DIR/phone.py"
private_file /run/agentv-test-phone.conf <<EOF
network={
  ssid="$ssid"
  key_mgmt=WPA-PSK
  proto=RSN
  pairwise=CCMP
  group=CCMP
  psk="$password"
}
EOF
ssh_sudo "ip netns exec phone ip link set lo up
ip netns exec phone sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 net.ipv4.conf.$phone_if.rp_filter=0
ip netns exec phone ip link set $phone_if up
ip netns exec phone wpa_supplicant -B -i $phone_if -c /run/agentv-test-phone.conf -P /run/agentv-test-phone-wpa.pid" >"$RUN_DIR/phone.log" 2>&1 || true
associated() {
  local _
  for _ in $(seq 1 30); do
    ssh_sudo "ip netns exec phone iw dev $phone_if link" 2>/dev/null | grep -q "^Connected to" && return 0
    sleep 1
  done
  return 1
}
check "the phone joins the hotspot with its password" associated
ssh_sudo "ip netns exec phone python3 -I /tmp/agentv-phone.py dhcp $phone_if" >"$RUN_DIR/dhcp.json" 2>&1 || true
cat "$RUN_DIR/dhcp.json"
phone_address=$(jq -r '.address // empty' "$RUN_DIR/dhcp.json" 2>/dev/null || true)
check "dnsmasq gives it an address" bash -c "[[ $phone_address == 10.42.0.* ]]"
check "with the box as its name server" jq -e '.dns == "10.42.0.1"' "$RUN_DIR/dhcp.json"
check "and the captive page's address (RFC 8910)" jq -e '.captive == "http://10.42.0.1/"' "$RUN_DIR/dhcp.json"
ssh_sudo "ip netns exec phone ip addr add $phone_address/24 dev $phone_if" >/dev/null 2>&1 || true

for name in captive.apple.com connectivitycheck.gstatic.com example.org; do
  answer=$(ssh_sudo "ip netns exec phone python3 -I /tmp/agentv-phone.py dns 10.42.0.1 $name" 2>/dev/null || true)
  check "$name points at the box" test "$answer" = "10.42.0.1"
done

# What iOS and Android ask, to see if they're online, lands on the captive
# page.
phone_curl() {
  ssh_sudo "ip netns exec phone curl -s --max-time 10 $*" 2>/dev/null || true
}
ios=$(phone_curl "-o /dev/null -w '%{http_code} %{redirect_url}' --resolve captive.apple.com:80:10.42.0.1 http://captive.apple.com/hotspot-detect.html")
check "iOS's check is sent to the captive page ($ios)" test "$ios" = "302 http://10.42.0.1/"
android=$(phone_curl "-o /dev/null -w '%{http_code} %{redirect_url}' --resolve connectivitycheck.gstatic.com:80:10.42.0.1 http://connectivitycheck.gstatic.com/generate_204")
check "and so is Android's ($android)" test "$android" = "302 http://10.42.0.1/"
page=$(phone_curl "http://10.42.0.1/")
check "the captive page is there" grep -q "companion-web/setup.ts" <<<"$page"
not_tv() {
  [[ $(phone_curl "-o /dev/null -w '%{http_code}' http://10.42.0.1/api/home") == "404" &&
    $(phone_curl "-o /dev/null -w '%{http_code}' http://10.42.0.1:3000/health") == "000" ]]
}
check "and nothing of the TV's own" not_tv
listed=$(phone_curl "http://10.42.0.1/api/setup/networks")
check "it lists the home Wi-Fi" jq -e --arg ssid "$HOME_SSID" '.networks | map(.ssid) | index($ssid) != null' <<<"$listed"

# A wrong password: the hotspot comes back, with the reason.
join() {
  jq -cn --arg ssid "$HOME_SSID" --arg password "$1" '{ssid: $ssid, password: $password}' | private_file /run/agentv-test-join.json
  phone_curl "-H 'Content-Type: application/json' -d @/run/agentv-test-join.json http://10.42.0.1/api/setup/wifi"
}
asked=$(join "not-the-password")
check "the phone asks the box to join it" jq -e '.ok == true' <<<"$asked"
came_back() {
  local _
  for _ in $(seq 1 120); do
    jq -e --arg ssid "$HOME_SSID" '.on == true and .error == "that password didn'"'"'t work for \($ssid)"' <<<"$(state)" >/dev/null && return 0
    sleep 1
  done
  return 1
}
check "a wrong password opens the hotspot again, with the reason" came_back
state >"$RUN_DIR/state-wrong.json"
cat "$RUN_DIR/state-wrong.json"
no_file() {
  [[ -z $(ssh_sudo "ls /etc/NetworkManager/system-connections/ | grep '^agentv-'" 2>/dev/null) ]]
}
check "and leaves no connection behind" no_file
check "the phone joins it again" associated
told=$(phone_curl "http://10.42.0.1/api/setup/state")
check "and the captive page hears why" jq -e --arg ssid "$HOME_SSID" '.error == "that password didn'"'"'t work for \($ssid)"' <<<"$told"

# The right one.
join "$HOME_PASSWORD" >"$RUN_DIR/join.json"
joined() {
  local _
  for _ in $(seq 1 120); do
    jq -e --arg ssid "$HOME_SSID" '.on == false and .joined.ssid == $ssid' <<<"$(state)" >/dev/null && return 0
    sleep 1
  done
  return 1
}
check "the right password joins the home Wi-Fi" joined
state >"$RUN_DIR/state-joined.json"
cat "$RUN_DIR/state-joined.json"
on_home() {
  [[ $(ssh_guest "nmcli -g GENERAL.CONNECTION device show $box_if" 2>/dev/null) == "$HOME_SSID" ]] &&
    ssh_guest "ip -4 -o addr show dev $box_if" 2>/dev/null | grep -q "inet 192\.168\.77\."
}
check "the box is on it, with an address from it" on_home
check "and state.json says where" jq -e '.joined.address | startswith("192.168.77.")' "$RUN_DIR/state-joined.json"
check "the hotspot is closed" closed
check "its firewall holes are gone" bash -c "[[ $(holes) == 0 ]]"
gone() {
  ! ssh_guest "nmcli -g NAME connection show" 2>/dev/null | grep -qx agentv-setup &&
    ! ssh_guest "pgrep -f 'dnsmasq.*10.42.0.1'" >/dev/null 2>&1
}
check "and so are its network and its dnsmasq" gone
private() {
  local file
  file=$(ssh_sudo "ls /etc/NetworkManager/system-connections/ | grep '^agentv-'" 2>/dev/null | head -n 1)
  [[ -n $file && $(ssh_sudo "stat -c '%a %U' '/etc/NetworkManager/system-connections/$file'" 2>/dev/null) == "600 root" ]]
}
check "the home Wi-Fi is kept where only root can read it" private
ssh_sudo "journalctl -b --no-pager" >"$RUN_DIR/journal.txt" 2>/dev/null || true
check "the password is in no log" bash -c "! grep -q '$HOME_PASSWORD' '$RUN_DIR/journal.txt'"

# The welcome screen moves on to pairing.
# Read for up to 15 s. check keeps what it runs quiet, so what OCR read is
# printed after it, when it didn't find it.
before=$FAILURES
check "the welcome screen says the TV is on the home Wi-Fi, and to pair the phone (OCR)" ocr_finds welcome-joined "tv is on|pair it" 15
if (( FAILURES > before )); then
  capture_console "failure-hotspot-joined"
  log "What OCR read on the welcome screen:"
  cat "$RUN_DIR/welcome-joined.txt"
  log "What the screen daemon says is in front, and the hotspot's state:"
  screen_status
  state
  print_screen "$RUN_DIR/.ocr.ppm"
else
  capture_console "success-hotspot-joined"
fi
paired_qr() {
  ssh_guest "curl -fsS http://127.0.0.1:3000/api/phones" 2>/dev/null | jq -e --arg net "192.168.77." '.pairing.url // "" | contains($net)' >/dev/null
}
check "with a code that pairs the phone at the box's address there" paired_qr

ssh_guest "journalctl -b --no-pager -u agentv-hotspot -u agentv-hotspot-drop" >"$RUN_DIR/hotspot.log" 2>&1 || true
stop_vm
finish
