#!/bin/bash
#
# Wi-Fi after setup on an installed box (ADR-084, T16.2): Settings changes
# the Wi-Fi with the hotspot closed, and a box that loses its network opens
# the hotspot again by itself, takes a network from the phone and comes back.
#
# The VM has no Wi-Fi card, so it gets three of the kernel's simulated radios
# (mac80211_hwsim), as s4-hotspot does: the box's own, a phone's and a home
# Wi-Fi's, the last two in network namespaces of their own.
#
# With setup done:
#   - Settings' own routes look at the networks nearby and join the home
#     Wi-Fi, with no hotspot. A wrong password for it leaves the box on the
#     network it was on, says why, and opens no hotspot.
#   - The home Wi-Fi goes away. Within the wait, shortened for the check, the
#     hotspot opens by itself and home says the TV is offline, with its QR
#     code.
#   - The home Wi-Fi comes back, as after a router restarts. With nobody on
#     the hotspot it closes to look, and the box is back on its network by
#     itself.
#   - The home Wi-Fi goes for good and another one is there. The hotspot
#     opens again and the phone joins it. A phone that's only joined doesn't
#     hold it open: it still closes to look. Once the phone opens the page,
#     the same one setup uses, the hotspot stays open past its wait. With an
#     adult PIN set the page's join needs it. The network the phone picks is
#     joined, the hotspot closes, and the password is in no log.
#
# The VM's cable is how this check reaches the box, so the watch is told not
# to count it (AGENTV_HOTSPOT_WATCH_SKIP), which is what that's for.

# shellcheck disable=SC2016 # the $names in jq's filters are jq's own

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

HOME_SSID=home-wifi-test
HOME_PASSWORD=home-pass-4826
NEW_SSID=new-router-test
NEW_PASSWORD=new-pass-7315
PIN=4826
TV=http://127.0.0.1:3000

start_vm_from_base
wait_for_ssh 300 failure-wifi-ssh-timeout || exit 1
passwordless_sudo
wait_tv 240 >/dev/null || { capture_console "failure-wifi-no-tv"; check "the TV session came up" false; stop_vm; finish; }

# The watch came with this change. The Nightly's edge leg runs the checks on
# edge's last build, which may be from before it, so on a box without it this
# waits.
if ! ssh_guest "test -f /usr/lib/systemd/system/agentv-hotspot-watch.service"; then
  log "This agentv has no Wi-Fi in Settings yet ($(guest "agentv version" 2>/dev/null | head -n 1)); T16.2 waits for it"
  stop_vm
  finish
  exit 0
fi

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
wait_home 60 >/dev/null || true
check "setup is done" jq -e '.setup.done == true' <<<"$(ssh_guest "curl -fsS --max-time 5 $TV/api/state" 2>/dev/null)"
check "the watch for a lost network runs from boot" ssh_guest "systemctl is-active agentv-hotspot-watch.service"

state() {
  ssh_guest "cat /run/agentv-hotspot/state.json" 2>/dev/null || echo '{}'
}
network() {
  ssh_guest "curl -fsS --max-time 5 $TV/api/network" 2>/dev/null || echo '{}'
}
hotspot_on() {
  jq -e '.on == true' <<<"$(state)" >/dev/null
}
closed() {
  [[ $(ssh_guest "systemctl is-active agentv-hotspot.service" 2>/dev/null) != "active" ]] && ! hotspot_on
}
# How many times the hotspot's unit has started this boot.
opened_times() {
  ssh_sudo "journalctl -b --no-pager -u agentv-hotspot.service" 2>/dev/null | grep -c "is on, with the setup page" || true
}
# wait_for <seconds> <command...>: until it's true.
wait_for() {
  local seconds=$1 started=$SECONDS
  shift
  while (( SECONDS - started < seconds )); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
# Passwords go to the box through stdin, never on sudo's command line, which
# sudo writes to the journal.
private_file() {
  ssh_guest "sudo sh -c 'umask 077 && cat >$1'"
}

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
cable_if=$(ssh_guest "nmcli -t -f DEVICE,TYPE device status | awk -F: '\$2 == \"ethernet\" { print \$1; exit }'" 2>/dev/null || true)
check "and the box keeps one for itself" test -n "$box_if"
log "The box's Wi-Fi is $box_if, and its cable $cable_if"

# access_point <ssid> <password> <address>: a Wi-Fi network on the home
# radio, with WPA2 and addresses from its own dnsmasq.
access_point() {
  private_file /run/agentv-test-home.conf <<EOF
network={
  ssid="$1"
  mode=2
  frequency=2437
  key_mgmt=WPA-PSK
  proto=RSN
  pairwise=CCMP
  group=CCMP
  psk="$2"
}
EOF
  ssh_sudo "ip netns exec home ip link set lo up
ip netns exec home ip link set $home_if up
ip netns exec home wpa_supplicant -B -i $home_if -c /run/agentv-test-home.conf -P /run/agentv-test-home-wpa.pid
ip netns exec home ip addr add $3.1/24 dev $home_if
ip netns exec home dnsmasq --conf-file=/dev/null --port=0 --interface=$home_if --bind-interfaces \
  --dhcp-range=$3.10,$3.50,255.255.255.0,1h \
  --pid-file=/run/agentv-test-home-dnsmasq.pid --dhcp-leasefile=/run/agentv-test-home.leases" >>"$RUN_DIR/home.log" 2>&1 || true
}
# The router's plug pulled.
access_point_off() {
  ssh_sudo 'for pid in /run/agentv-test-home-wpa.pid /run/agentv-test-home-dnsmasq.pid; do [[ -f $pid ]] && kill "$(cat "$pid")"; rm -f "$pid"; done
sleep 1
ip netns exec home ip addr flush dev '"$home_if"'
ip netns exec home ip link set '"$home_if"' down
rm -f /run/agentv-test-home.leases' >>"$RUN_DIR/home.log" 2>&1 || true
}
is_access_point() {
  ssh_sudo "ip netns exec home iw dev $home_if info" 2>/dev/null | grep -q "type AP"
}
home_up() {
  wait_for 20 is_access_point
}

access_point "$HOME_SSID" "$HOME_PASSWORD" 192.168.77
check "the home Wi-Fi is up as an access point" home_up

# --- Settings, with the hotspot closed ---------------------------------------

# Settings' routes are on the TV's own port. A phone's port has none of them.
tv_post() {
  ssh_guest "curl -s --max-time 10 -X POST -H 'Content-Type: application/json' $TV$1" 2>/dev/null || true
}
phones_port=$(ssh_guest "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:3001/api/network/join" 2>/dev/null || true)
check "a phone's port has no way to change the Wi-Fi ($phones_port)" test "$phones_port" != 200
listed() {
  ssh_guest "curl -fsS --max-time 5 $TV/api/network/networks" 2>/dev/null | jq -e --arg ssid "$1" '.networks | map(.ssid) | index($ssid) != null' >/dev/null
}
looks_and_lists() {
  local _
  for _ in $(seq 1 10); do
    tv_post /api/network/scan >/dev/null
    wait_for 8 listed "$1" && return 0
  done
  return 1
}
check "Settings' look lists the home Wi-Fi, with no hotspot" looks_and_lists "$HOME_SSID"
check "and the hotspot stayed closed for it" closed

# join_from_settings <ssid> <password>: as Settings' page asks, with the
# password from a file only root reads, so it's on no command line.
join_from_settings() {
  jq -cn --arg ssid "$1" --arg password "$2" '{ssid: $ssid, password: $password}' | private_file /run/agentv-test-join.json
  ssh_sudo "curl -s --max-time 10 -H 'Content-Type: application/json' -d @/run/agentv-test-join.json $TV/api/network/join" 2>/dev/null || true
}
on_wifi() {
  [[ $(ssh_guest "nmcli -g GENERAL.CONNECTION device show $box_if" 2>/dev/null) == "$1" ]] &&
    ssh_guest "ip -4 -o addr show dev $box_if" 2>/dev/null | grep -q "inet $2\."
}
asked=$(join_from_settings "$HOME_SSID" "$HOME_PASSWORD")
check "Settings asks the box to join the home Wi-Fi" jq -e --arg ssid "$HOME_SSID" '.ok == true and .joining == $ssid' <<<"$asked"
before=$FAILURES
check "the box joins it, with an address from it" wait_for 90 on_wifi "$HOME_SSID" 192.168.77
(( FAILURES == before )) || { state; ssh_sudo "journalctl -b --no-pager -u agentv-hotspot-drop.service" | tail -n 30; }
worked() {
  jq -e '.joining == null and .problem == null' <<<"$(network)" >/dev/null
}
check "and Settings hears it worked" wait_for 30 worked
check "state.json says which Wi-Fi the box is on" jq -e --arg ssid "$HOME_SSID" '.wifi == $ssid' <<<"$(state)"
marked() {
  ssh_guest "curl -fsS --max-time 5 $TV/api/network/networks" 2>/dev/null | jq -e --arg ssid "$HOME_SSID" '.networks | map(select(.current)) | map(.ssid) == [$ssid]' >/dev/null
}
check "the list marks it" marked
check "no hotspot opened for it" test "$(opened_times)" = 0

# A wrong password, from Settings: the box goes back to the network it was
# on, and no hotspot opens.
asked=$(join_from_settings "$HOME_SSID" "not-the-password")
check "Settings asks again, with a wrong password" jq -e '.ok == true' <<<"$asked"
said_why() {
  jq -e --arg ssid "$HOME_SSID" '.joining == null and .problem == {ssid: $ssid, why: "password"}' <<<"$(network)" >/dev/null
}
before=$FAILURES
check "it says the password didn't work" wait_for 150 said_why
(( FAILURES == before )) || { network; state; ssh_sudo "journalctl -b --no-pager -u agentv-hotspot-drop.service" | tail -n 30; }
check "the box is back on the network it was on" wait_for 60 on_wifi "$HOME_SSID" 192.168.77
check "and no hotspot opened" test "$(opened_times)" = 0
one_kept() {
  [[ $(ssh_sudo "ls /etc/NetworkManager/system-connections/ | grep -c '^agentv-'" 2>/dev/null) == 1 ]]
}
check "only the network that works is kept" one_kept

# --- The network goes ---------------------------------------------------------

# The watch, with its waits shortened and the VM's cable left out.
ssh_sudo "install -d /run/systemd/system/agentv-hotspot-watch.service.d
printf '%s\n' '[Service]' 'Environment=AGENTV_HOTSPOT_LOST_AFTER=15' 'Environment=AGENTV_HOTSPOT_RETRY_AFTER=45' 'Environment=AGENTV_HOTSPOT_REJOIN_WAIT=25' 'Environment=AGENTV_HOTSPOT_WATCH_SKIP=$cable_if' >/run/systemd/system/agentv-hotspot-watch.service.d/test.conf
systemctl daemon-reload
systemctl restart agentv-hotspot-watch.service" >"$RUN_DIR/watch-dropin.log" 2>&1 || true
sleep 20
check "on its Wi-Fi, the watch leaves the hotspot closed" closed

access_point_off
log "The home Wi-Fi is off"
before=$FAILURES
check "with no network, the hotspot opens by itself within the wait" wait_for 120 hotspot_on
(( FAILURES == before )) || { state; ssh_guest "nmcli device status"; ssh_sudo "journalctl -b --no-pager -u agentv-hotspot-watch.service -u agentv-hotspot.service" | tail -n 40; }
check "state.json says the watch opened it" jq -e '.watch == true' <<<"$(state)"
ssid=$(jq -r '.ssid // empty' <<<"$(state)")
password=$(jq -r '.password // empty' <<<"$(state)")
log "The hotspot: $ssid"
ap_mode() {
  ssh_guest "iw dev $box_if info" 2>/dev/null | grep -q "type AP"
}
check "the box's radio is an access point" ap_mode
page_has_hotspot() {
  jq -e --arg ssid "$ssid" '.hotspot.ssid == $ssid' <<<"$(network)" >/dev/null
}
page_has_none() {
  jq -e '.hotspot == null and .joining == null' <<<"$(network)" >/dev/null
}
check "the TV's page hears the hotspot is open" wait_for 20 page_has_hotspot
qr() {
  ssh_guest "curl -fsS $TV/api/hotspot/qr" 2>/dev/null | grep -q "<svg"
}
check "with its QR code" qr
before=$FAILURES
check "home says the TV is offline (OCR)" ocr_finds offline "tv is offline|pick your wi" 25
if (( FAILURES > before )); then
  capture_console "failure-wifi-offline"
  log "What OCR read on home:"
  cat "$RUN_DIR/offline.txt"
  screen_status
  print_screen "$RUN_DIR/.ocr.ppm"
else
  capture_console "success-wifi-offline"
fi

# --- The router comes back ----------------------------------------------------

opened=$(opened_times)
access_point "$HOME_SSID" "$HOME_PASSWORD" 192.168.77
check "the home Wi-Fi is back, as after a router restarts" home_up
before=$FAILURES
check "with nobody on the hotspot, it closes to look, and the box is back on its Wi-Fi by itself" wait_for 180 on_wifi "$HOME_SSID" 192.168.77
(( FAILURES == before )) || { state; ssh_guest "nmcli device status"; ssh_sudo "journalctl -b --no-pager -u agentv-hotspot-watch.service" | tail -n 40; }
check "the hotspot is closed" wait_for 20 closed
check "and it's no longer the watch's" jq -e '.watch == null' <<<"$(state)"
check "the TV's page hears it's gone" wait_for 20 page_has_none
log "The hotspot opened $(( $(opened_times) - opened )) more time(s) while it looked"

# --- A new router: the phone picks it -----------------------------------------

# An adult PIN, set as Settings sets it, so the hotspot's page has to ask.
ssh_guest "curl -fsS --max-time 5 -X PUT -H 'Content-Type: application/json' -d '{\"pin\":\"$PIN\"}' $TV/api/pin" >"$RUN_DIR/pin.json" 2>&1 || true
check "an adult PIN is set" jq -e '.ok == true' "$RUN_DIR/pin.json"
trap 'pin_off_then_cleanup "$PIN"' EXIT

access_point_off
access_point "$NEW_SSID" "$NEW_PASSWORD" 192.168.78
check "the old Wi-Fi is gone, and another one is up" home_up
before=$FAILURES
check "the hotspot opens by itself again" wait_for 150 hotspot_on
(( FAILURES == before )) || { state; ssh_guest "nmcli device status"; ssh_sudo "journalctl -b --no-pager -u agentv-hotspot-watch.service -u agentv-hotspot.service" | tail -n 40; }
check "with the same name and password as before, in the same boot" jq -e --arg ssid "$ssid" --arg password "$password" '.ssid == $ssid and .password == $password' <<<"$(state)"
saw_new() {
  ssh_guest "cat /run/agentv-hotspot/networks.json" 2>/dev/null | jq -e --arg ssid "$NEW_SSID" 'map(.ssid) | index($ssid) != null' >/dev/null
}
check "it saw the new Wi-Fi before it opened" saw_new

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
  ssh_sudo "ip netns exec phone iw dev $phone_if link" 2>/dev/null | grep -q "^Connected to"
}
check "the phone joins the hotspot with the password on the TV" wait_for 30 associated
ssh_sudo "ip netns exec phone python3 -I /tmp/agentv-phone.py dhcp $phone_if" >"$RUN_DIR/dhcp.json" 2>&1 || true
cat "$RUN_DIR/dhcp.json"
phone_address=$(jq -r '.address // empty' "$RUN_DIR/dhcp.json" 2>/dev/null || true)
check "and gets an address ($phone_address)" grep -q '^10\.42\.0\.' <<<"$phone_address"
ssh_sudo "ip netns exec phone ip addr add $phone_address/24 dev $phone_if" >/dev/null 2>&1 || true

phone_curl() {
  ssh_sudo "ip netns exec phone curl -s --max-time 10 $*" 2>/dev/null || true
}
# How many times the watch has closed the hotspot to look for the Wi-Fi the
# box knows.
looked_times() {
  ssh_sudo "journalctl -b --no-pager -u agentv-hotspot-watch.service" 2>/dev/null | grep -c "closes for a moment to look" || true
}
looked_since() {
  (( $(looked_times) > $1 ))
}

# The phone has joined and asked for nothing, as one does from a pocket.
# That doesn't hold the hotspot: at its next wait the watch still closes it
# to look, finds no Wi-Fi it knows, and opens it again.
looked=$(looked_times)
before=$FAILURES
check "a phone that's only joined doesn't hold the hotspot open: it still closes to look" wait_for 90 looked_since "$looked"
(( FAILURES == before )) || ssh_sudo "journalctl -b --no-pager -u agentv-hotspot-watch.service" | tail -n 20
check "and with the home Wi-Fi still gone, it opens again" wait_for 90 hotspot_on

# The phone knows the hotspot and goes back on it by itself. With the waits
# this short the hotspot may close to look once more before it has, so this
# takes as long as a few of them.
gets_page() {
  phone_curl "http://10.42.0.1/" | grep -q "companion-web/setup.ts"
}
before=$FAILURES
check "the phone is back on it by itself, and gets the page setup uses" wait_for 180 gets_page
(( FAILURES == before )) || { state; ssh_sudo "ip netns exec phone iw dev $phone_if link"; ssh_sudo "journalctl -b --no-pager -u agentv-hotspot-watch.service" | tail -n 20; }
listed_on_page=$(phone_curl "http://10.42.0.1/api/setup/networks")
check "which lists the new Wi-Fi, and says it's after setup and wants the PIN" jq -e --arg ssid "$NEW_SSID" '(.networks | map(.ssid) | index($ssid) != null) and .after == true and .pin == true' <<<"$listed_on_page"
settings_there=$(phone_curl "-o /dev/null -w '%{http_code}' http://10.42.0.1/api/network")
check "and nothing of Settings' own ($settings_there)" test "$settings_there" = 404

# With someone using its page, the watch leaves the hotspot open past its
# wait, so this phone keeps asking for the page for longer than the wait.
# Open at the end isn't enough to say so, since a hotspot that closed to
# look opens again: the watch never closed it at all.
looked=$(looked_times)
for _ in 1 2 3 4 5 6; do
  sleep 10
  phone_curl "-o /dev/null http://10.42.0.1/"
done
check "with someone using its page, the hotspot never closes to look" test "$(looked_times)" = "$looked"
check "it's open" hotspot_on
check "and the phone is still on it" associated

# page_join [<pin>]: the page's join, with the passwords from a file.
page_join() {
  jq -cn --arg ssid "$NEW_SSID" --arg password "$NEW_PASSWORD" --arg pin "${1:-}" '{ssid: $ssid, password: $password} + (if $pin == "" then {} else {pin: $pin} end)' | private_file /run/agentv-test-join.json
  phone_curl "-H 'Content-Type: application/json' -d @/run/agentv-test-join.json http://10.42.0.1/api/setup/wifi"
}
check "without the PIN, the page's join is refused" jq -e '.ok == false and .pin == true' <<<"$(page_join)"
check "and with a wrong one" jq -e '.ok == false and .pin == true' <<<"$(page_join 0000)"
check "and the hotspot is still open" hotspot_on
asked=$(page_join "$PIN")
check "with the PIN, the phone asks the box to join the new Wi-Fi" jq -e '.ok == true' <<<"$asked"
joined() {
  jq -e --arg ssid "$NEW_SSID" '.on == false and .joined.ssid == $ssid' <<<"$(state)" >/dev/null
}
before=$FAILURES
check "the box joins it" wait_for 120 joined
(( FAILURES == before )) || { state; ssh_sudo "journalctl -b --no-pager -u agentv-hotspot-drop.service" | tail -n 30; }
check "it's on it, with an address from it" wait_for 30 on_wifi "$NEW_SSID" 192.168.78
sleep 25
check "the hotspot is closed, and stays closed" closed
holes() {
  ssh_sudo "iptables -S; iptables -t nat -S" 2>/dev/null | grep -c "agentv-setup-hotspot" || true
}
check "its firewall holes are gone" test "$(holes)" = 0
check "the TV's page hears it's back" wait_for 20 page_has_none
no_notice() {
  ! ocr_finds back "tv is offline" 3
}
check "and home no longer says it's offline (OCR)" no_notice
capture_console "success-wifi-back"
ssh_sudo "journalctl -b --no-pager" >"$RUN_DIR/journal.txt" 2>/dev/null || true
no_passwords() {
  ! grep -qE "$HOME_PASSWORD|$NEW_PASSWORD|not-the-password" "$RUN_DIR/journal.txt"
}
check "neither Wi-Fi's password is in a log" no_passwords
no_pins() {
  ! grep -E "agentv-daemon|node\[" "$RUN_DIR/journal.txt" | grep -qE "pin.*\b($PIN|0000)\b"
}
check "nor a PIN typed on the hotspot's page" no_pins

ssh_guest "journalctl -b --no-pager -u agentv-hotspot -u agentv-hotspot-drop -u agentv-hotspot-watch" >"$RUN_DIR/hotspot.log" 2>&1 || true
stop_vm
finish
