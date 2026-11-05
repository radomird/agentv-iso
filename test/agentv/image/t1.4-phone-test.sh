#!/bin/bash
#
# T1.4: the phone's way through the USB stick's first screen, with a
# stand-in phone.
#
# The VM starts with no Wi-Fi card, so the first screen's code is the box's
# address on the home network, with the token in it, and a phone there gets
# the page but can't erase anything without the token. Then the kernel's
# simulated radios (mac80211_hwsim) give the live system a Wi-Fi card: the
# first screen opens its own network and shows its code. The phone, the
# other radio in a network namespace of its own, joins with the password
# from the code, over the simulated air. It gets an address, every name
# points at the box, and the page comes with the token. "Erase and install"
# is refused without it and starts the install with it, once.
#
# The box restarts by itself, opens the same network with the same password,
# and the phone joins it again and gets the installed box's page.
#
# The installed box's account has a password nobody knows, so while it
# installs, the harness gives it sudo for this VM only, and the simulated
# radios at boot, the way tv.sh's passwordless_sudo does on the base image.

# shellcheck disable=SC2016 # the $names in jq's filters are jq's own

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/first-screen.sh"
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# shellcheck disable=SC2034 # ssh_guest reads it
GUEST_USER=agentv

log "Booting the USB stick onto a blank disk, with no Wi-Fi card"
boot_stick t1.4
wait_for_live_root_ssh 300 || { stop_vm; finish; }
check "AgenTV's first screen comes up (OCR)" wait_for_screen "of 12" 300

phone_json() {
  ssh_live_root "cat /run/agentv-first-screen/phone.json" 2>/dev/null || echo '{}'
}
# wait_mode <mode> <seconds>
wait_mode() {
  local started=$SECONDS
  until jq -e --arg mode "$1" '.mode == $mode' <<<"$(phone_json)" >/dev/null 2>&1; do
    (( SECONDS - started < $2 )) || return 1
    sleep 2
  done
}

# The home network: user-mode networking gives the live system 10.0.2.15.
check "with no Wi-Fi card, the code is the box's address on the home network" wait_mode home 90
phone_json >"$RUN_DIR/phone-home.json"
cat "$RUN_DIR/phone-home.json"
url=$(jq -r '.qr // empty' "$RUN_DIR/phone-home.json")
token=${url##*\?t=}
check "with the token in it" bash -c '[[ $1 =~ ^http://10\.0\.2\.15/\?t=[A-Za-z0-9_-]{22}$ ]]' _ "$url"
check "the TV says to set it up from the phone (OCR)" wait_for_screen "from your phone" 30
capture_console "success-T1.4-home-code"
home_page=$(ssh_live_root "curl -s --max-time 10 http://10.0.2.15/" 2>/dev/null || true)
check "a phone on the home network gets the page, but not the token" \
  bash -c '[[ $1 == *"erase and install"* && $1 == *"const TOKEN = \"\""* && $1 != *"$2"* ]]' _ "$home_page" "$token"
home_post() {
  ssh_live_root "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json' -d '$1' http://10.0.2.15/api/first/install" 2>/dev/null || true
}
check "T1.4 erase and install from the home network without the token is refused" test "$(home_post '{"disk": "/dev/vda"}')" = 403

# A Wi-Fi card that can host a network: two simulated radios, the box's and
# the phone's.
check "the live system gets two simulated Wi-Fi radios" ssh_live_root "modprobe mac80211_hwsim radios=2"
check "T1.4 the first screen opens its own Wi-Fi network" wait_mode hotspot 120
phone_json >"$RUN_DIR/phone-hotspot.json"
jq '.password = "(kept out of the log)"' "$RUN_DIR/phone-hotspot.json"
ssid=$(jq -r '.ssid // empty' "$RUN_DIR/phone-hotspot.json")
password=$(jq -r '.password // empty' "$RUN_DIR/phone-hotspot.json")
device=$(jq -r '.device // empty' "$RUN_DIR/phone-hotspot.json")
check "named AgenTV-, with a password" bash -c '[[ $1 =~ ^AgenTV-[0-9a-f]{4}$ && ${#2} == 10 ]]' _ "$ssid" "$password"
check "its code is the network's name and password" \
  jq -e --arg ssid "$ssid" --arg password "$password" '.qr == "WIFI:T:WPA;S:\($ssid);P:\($password);;"' "$RUN_DIR/phone-hotspot.json"
access_point() {
  ssh_live_root "iw dev $device info" 2>/dev/null | grep -q "type AP"
}
check "the box's radio is an access point" access_point
sleep 3
capture_console "success-T1.4-hotspot-code"

# The phone: the other radio, in a namespace of its own.
box_phy=$(ssh_live_root "cat /sys/class/net/$device/phy80211/name" 2>/dev/null || true)
phone_phy=$(ssh_live_root "ls /sys/class/ieee80211 | grep -vx '$box_phy' | head -n 1" 2>/dev/null || true)
ssh_live_root "ip netns add phone && iw phy $phone_phy set netns name phone" >"$RUN_DIR/netns.log" 2>&1 || true
phone_if=$(ssh_live_root "ip netns exec phone ls /sys/class/net | grep -vx lo | head -n 1" 2>/dev/null || true)
check "the phone's radio is in its own namespace" test -n "$phone_if"
phone_conf() {
  cat <<EOF
network={
  ssid="$ssid"
  key_mgmt=WPA-PSK
  proto=RSN
  pairwise=CCMP
  group=CCMP
  psk="$password"
}
EOF
}
phone_conf | ssh_live_root "umask 077 && cat >/run/agentv-test-phone.conf"
ssh_live_root "cat >/tmp/agentv-phone.py" <"$DIR/phone.py"
ssh_live_root "ip netns exec phone ip link set lo up
ip netns exec phone ip link set $phone_if up
ip netns exec phone wpa_supplicant -B -i $phone_if -c /run/agentv-test-phone.conf" >"$RUN_DIR/phone.log" 2>&1 || true
# associated <ssh command>: until the phone's radio is connected.
associated() {
  local _
  for _ in $(seq 1 30); do
    "$1" "ip netns exec phone iw dev $phone_if link" 2>/dev/null | grep -q "^Connected to" && return 0
    sleep 1
  done
  return 1
}
check "T1.4 the phone joins the live system's network with the password from the code" associated ssh_live_root
ssh_live_root "ip netns exec phone python3 -I /tmp/agentv-phone.py dhcp $phone_if" >"$RUN_DIR/dhcp.json" 2>&1 || true
cat "$RUN_DIR/dhcp.json"
phone_address=$(jq -r '.address // empty' "$RUN_DIR/dhcp.json" 2>/dev/null || true)
check "it gets an address" bash -c '[[ $1 == 10.42.0.* ]]' _ "$phone_address"
check "with the box as its name server" jq -e '.dns == "10.42.0.1"' "$RUN_DIR/dhcp.json"
check "and the page's address (RFC 8910)" jq -e '.captive == "http://10.42.0.1/"' "$RUN_DIR/dhcp.json"
ssh_live_root "ip netns exec phone ip addr add $phone_address/24 dev $phone_if" >/dev/null 2>&1 || true
answer=$(ssh_live_root "ip netns exec phone python3 -I /tmp/agentv-phone.py dns 10.42.0.1 captive.apple.com" 2>/dev/null || true)
check "every name points at the box" test "$answer" = 10.42.0.1

phone_curl() {
  ssh_live_root "ip netns exec phone curl -s --max-time 10 $*" 2>/dev/null || true
}
ios=$(phone_curl "-o /dev/null -w '%{http_code} %{redirect_url}' --resolve captive.apple.com:80:10.42.0.1 http://captive.apple.com/hotspot-detect.html")
check "iOS's check lands on the page ($ios)" test "$ios" = "302 http://10.42.0.1/"
page=$(phone_curl "http://10.42.0.1/")
check "the page comes with the token" bash -c '[[ $1 == *"const TOKEN = \"$2\""* ]]' _ "$page" "$token"
state=$(phone_curl "http://10.42.0.1/api/first")
check "it lists the disk the TV lists" jq -e '.step == 1 and (.disks | map(.path) | index("/dev/vda") != null)' <<<"$state"

install() {
  phone_curl "-o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '$1' http://10.42.0.1/api/first/install"
}
check "T1.4 erase and install without the token is refused" test "$(install '{"disk": "/dev/vda"}')" = 403
check "and with the wrong one" test "$(install '{"disk": "/dev/vda", "token": "not-the-token-from-the-tv"}')" = 403
check "and the TV is still on its first screen (OCR)" wait_for_screen "of 12" 10

# While it installs: the harness's key for the new account, and, for this VM
# only, sudo and the simulated radios at boot, written as soon as the
# install has made the account.
give_key
ssh_live_root "cat >/tmp/agentv-test-seed.sh" <<'EOF'
until [ -s /mnt/home/agentv/.ssh/authorized_keys ]; do sleep 0.2; done
printf '%s\n' 'agentv ALL=(ALL:ALL) NOPASSWD: ALL' >/mnt/etc/sudoers.d/zzz-agentv-test
chmod 440 /mnt/etc/sudoers.d/zzz-agentv-test
echo mac80211_hwsim >/mnt/etc/modules-load.d/zzz-agentv-test.conf
echo 'options mac80211_hwsim radios=2' >/mnt/etc/modprobe.d/zzz-agentv-test.conf
EOF
ssh_live_root "setsid -f bash /tmp/agentv-test-seed.sh >/dev/null 2>&1 </dev/null"

check "T1.4 erase and install with the token starts the install" test "$(install "{\"disk\": \"/dev/vda\", \"token\": \"$token\"}")" = 200
check "and the token works once" test "$(install "{\"disk\": \"/dev/vda\", \"token\": \"$token\"}")" = 409
moved_on() {
  local _
  for _ in $(seq 1 10); do
    jq -e '.step == 2 and .installing == "/dev/vda"' <<<"$(phone_curl "http://10.42.0.1/api/first")" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
check "the phone's page moves on to installing" moved_on

installed=0
wait_for_box t1.4 && installed=1
check "T1.4 it installed, and the box restarted by itself" test "$installed" = 1
(( installed )) || { stop_vm; finish; }
check "no question of Omarchy's on the screen while it installed (OCR every 10 s)" test -z "$QUESTIONS_SEEN"

check "the harness has sudo on this VM" ssh_guest "sudo -n true"
handed=$(ssh_guest "sudo -n cat /etc/agentv/hotspot.json" 2>/dev/null || true)
check "the installed box has the network's name and password" \
  jq -e --arg ssid "$ssid" --arg password "$password" '.ssid == $ssid and .password == $password' <<<"$handed"
check "readable by root only" test "$(ssh_guest "sudo -n stat -c %a /etc/agentv/hotspot.json" 2>/dev/null)" = 600

# The installed box's own setup hotspot, with the same name and password.
box_state() {
  ssh_guest "cat /run/agentv-hotspot/state.json" 2>/dev/null || echo '{}'
}
same_network() {
  local _
  for _ in $(seq 1 90); do
    jq -e --arg ssid "$ssid" '.on == true and .ssid == $ssid' <<<"$(box_state)" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
check "T1.4 the installed box opens the same network, with the same password" same_network
box_state | jq '.password = "(kept out of the log)"' >"$RUN_DIR/box-hotspot.json" 2>/dev/null || true
cat "$RUN_DIR/box-hotspot.json"
check "with the same password" jq -e --arg password "$password" '.password == $password' <<<"$(box_state)"

# The phone again: the radio that isn't the box's.
box_device=$(jq -r '.device // empty' <<<"$(box_state)")
box_phy=$(ssh_guest "cat /sys/class/net/$box_device/phy80211/name" 2>/dev/null || true)
phone_phy=$(ssh_guest "ls /sys/class/ieee80211 | grep -vx '$box_phy' | head -n 1" 2>/dev/null || true)
ssh_guest "sudo -n sh -c 'ip netns add phone && iw phy $phone_phy set netns name phone'" >"$RUN_DIR/netns-box.log" 2>&1 || true
box_sudo() {
  ssh_guest "sudo -n sh -c $(printf %q "$1")"
}
phone_if=$(box_sudo "ip netns exec phone ls /sys/class/net | grep -vx lo | head -n 1" 2>/dev/null || true)
phone_conf | ssh_guest "sudo -n sh -c 'umask 077 && cat >/run/agentv-test-phone.conf'"
ssh_guest "cat >/tmp/agentv-phone.py" <"$DIR/phone.py"
box_sudo "ip netns exec phone ip link set lo up
ip netns exec phone ip link set $phone_if up
ip netns exec phone wpa_supplicant -B -i $phone_if -c /run/agentv-test-phone.conf" >"$RUN_DIR/phone-box.log" 2>&1 || true
check "T1.4 the phone joins it again, with what it already had" associated box_sudo
box_sudo "ip netns exec phone python3 -I /tmp/agentv-phone.py dhcp $phone_if" >"$RUN_DIR/dhcp-box.json" 2>&1 || true
phone_address=$(jq -r '.address // empty' "$RUN_DIR/dhcp-box.json" 2>/dev/null || true)
box_sudo "ip netns exec phone ip addr add $phone_address/24 dev $phone_if" >/dev/null 2>&1 || true
box_page=$(box_sudo "ip netns exec phone curl -s --max-time 10 http://10.42.0.1/" 2>/dev/null || true)
check "T1.4 and gets the installed box's page" grep -q "companion-web/setup.ts" <<<"$box_page"
capture_console "success-T1.4-tv-setup"

stop_vm
finish
