#!/bin/bash
#
# A box moves to the next Omarchy release the way a stable box will: first
# the newer agentv on the Omarchy it has, then Omarchy's own update, from
# the TV. Then Restart and Shut down from the TV still work on the new
# Omarchy. For AgenTV's move from Omarchy 4.0.6 to 4.5 that's a box
# installed from 0.1.4's ISO, and it's where 4.5 used to break things: its
# update takes away sudo grants named like its own, which the update from
# the TV had, and Restart and Shut down went through commands 4.5 folded
# into omarchy-system.
#
# Runs only when the image run names the channel that has the next release
# (AGENTV_TEST_OMARCHY_CHANNEL, rc until stable serves it), with a newer
# agentv to update to (AGENTV_TEST_UPDATE_REPO, as S0.5).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/repos.sh"

if [[ -z ${AGENTV_TEST_OMARCHY_CHANNEL:-} || -z ${AGENTV_TEST_UPDATE_REPO:-} ]]; then
  log "No Omarchy channel to move to, or no newer agentv; skipping"
  exit 0
fi
base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

release=$(sed -n '1{s/[[:space:]]//g;p;}' "$ROOT/.github/omarchy-release")
want=${release#v}

port=$((SSH_PORT + 4))
(cd "$AGENTV_TEST_UPDATE_REPO" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

start_vm_from_base
wait_for_ssh 300 failure-omarchy-update-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
ssh_sudo "install -d /etc/agentv && echo http://10.0.2.2:$port >/etc/agentv/repository"
omarchy_before=$(ssh_guest "pacman -Q omarchy" | cut -d' ' -f2)
log "Installed: omarchy $omarchy_before, agentv $(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)"

# until_file <jq filter> <file> <seconds>: until the filter is true.
until_file() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "cat $2 2>/dev/null" | jq -r "$1" 2>/dev/null) == "true" ]] && return 0
    sleep 3
  done
  return 1
}

# back_up <boot id before> <what>: waits for the box to come back as a new
# boot, with home in front. It's set up, so it shows no welcome page.
back_up() {
  wait_for_ssh 300 "failure-omarchy-update-$2-ssh-timeout" || return 1
  [[ $(ssh_guest "cat /proc/sys/kernel/random/boot_id") != "$1" ]] || return 1
  wait_home 240 >/dev/null
}

# 1. The newer agentv, on the Omarchy the box has, as S0.5 takes it. The
# test user may use sudo for this part only, as someone at the box would.
ssh_sudo "printf '%s\n' '$GUEST_USER ALL=(ALL:ALL) NOPASSWD: ALL' 'Defaults:$GUEST_USER !authenticate' >/etc/sudoers.d/zzz-agentv-test && chmod 440 /etc/sudoers.d/zzz-agentv-test"
update="timeout 2400 env OMARCHY_UPDATE_LOGGED=1 agentv update -y --untested"
ssh_guest "bash -lc $(printf %q "$update") </dev/null" >"$RUN_DIR/agentv-update.log" 2>&1 || true
agentv_now=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
check "first, agentv $AGENTV_TEST_UPDATE_VERSION on omarchy $omarchy_before (now agentv $agentv_now)" \
  test "$agentv_now" = "$AGENTV_TEST_UPDATE_VERSION"
ssh_sudo "rm -f /etc/sudoers.d/zzz-agentv-test"
if needs_restart; then
  boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
  ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
  sleep 20
  back_up "$boot" agentv-restart || { check "the box came back after the agentv update's restart" false; stop_vm; finish; }
fi

# 2. Omarchy's next release, from the TV. Edge lets the update go ahead
# without the nightly run's tested.json, as the update-tv check does, and
# the box's only newer agentv is the one it has now.
check "the box takes Omarchy from $AGENTV_TEST_OMARCHY_CHANNEL" omarchy_channel "$AGENTV_TEST_OMARCHY_CHANNEL"
ssh_sudo "echo edge >/etc/agentv/channel"
kernel=$(ssh_guest "uname -r")
boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
guest "agentv screen update check" >"$RUN_DIR/screen.log" 2>&1 || true
check "Check now finds omarchy $want" \
  until_file "(.omarchy.available // \"\") | startswith(\"$want-\")" /var/lib/agentv/update/status.json 300
ssh_guest "cat /var/lib/agentv/update/status.json" >"$RUN_DIR/status.json" 2>&1 || true
guest "agentv screen update install" >>"$RUN_DIR/screen.log" 2>&1 || true
check "Install now starts the update" until_file '.state == "running"' /var/lib/agentv/update/progress.json 60
log "Waiting for Omarchy's update to finish"
until_file '.state != "running"' /var/lib/agentv/update/progress.json 3000 || true
ssh_guest "cat /var/lib/agentv/update/progress.json" >"$RUN_DIR/progress.json" 2>&1 || true
ssh_guest "cat /var/lib/agentv/update/update.log" >"$RUN_DIR/update.log" 2>&1 || true
check "the update from the TV finishes ($(jq -r '"\(.state): \(.detail)"' "$RUN_DIR/progress.json" 2>/dev/null))" \
  jq -e '.state == "done" or .state == "restarting"' "$RUN_DIR/progress.json"
jq -e '.state == "done" or .state == "restarting"' "$RUN_DIR/progress.json" >/dev/null 2>&1 || tail -n 40 "$RUN_DIR/update.log"
if [[ $(jq -r .state "$RUN_DIR/progress.json") == "restarting" ]]; then
  sleep 20
  back_up "$boot" omarchy-restart || { check "the box came back after Omarchy's update restarted it" false; stop_vm; finish; }
fi
omarchy_now=$(ssh_guest "pacman -Q omarchy" | cut -d' ' -f2)
check "the box is on omarchy $want (was $omarchy_before, now $omarchy_now)" test "${omarchy_now%-*}" = "$want"
check "and still on agentv $AGENTV_TEST_UPDATE_VERSION" test "$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)" = "$AGENTV_TEST_UPDATE_VERSION"
check "the sudo grant the update ran with is gone, and Omarchy didn't have to set it aside" \
  ssh_sudo "! ls /etc/sudoers.d/99-agentv-update-* /etc/sudoers.d/99-omarchy-nopasswd-* 2>/dev/null | grep -q . && ! grep -rqs 99-agentv /var/lib/omarchy/sudoers-quarantine"
log "Omarchy's update: $(jq -r .state "$RUN_DIR/progress.json"), kernel $kernel before, $(ssh_guest "uname -r") now"

# 3. Restart from the TV, on the new Omarchy: Settings → Power → Restart.
screen_home() {
  [[ $(front '.front.role // ""') == "home" ]] || return 1
  ocr_screen >"$RUN_DIR/$1.txt" 2>/dev/null || true
  capture_console "$1"
  grep -qiE "$HOME_TEXT" "$RUN_DIR/$1.txt"
}
power_menu() {
  local _
  for _ in $(seq 1 30); do
    guest "agentv screen settings power" >"$RUN_DIR/settings.json" 2>&1 || true
    jq -e '.ok == true' "$RUN_DIR/settings.json" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
check "Settings opens at Power on omarchy $want" power_menu
sleep 2
for key in enter enter; do
  guest "agentv input key $key" >>"$RUN_DIR/input.log" 2>&1 || true
  sleep 1
done
sleep 1
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
chosen=$SECONDS
down=""
while (( SECONDS - chosen < 60 )); do
  if [[ $(ssh_guest "cat /proc/sys/kernel/random/boot_id" 2>/dev/null) != "$boot" ]]; then
    down=$(( SECONDS - chosen ))
    break
  fi
  sleep 0.5
done
check "Restart from the TV took the box down on omarchy $want (${down:-over 60} s)" test -n "$down"
back_up "$boot" power-restart || { check "the box came back after Restart from the TV" false; stop_vm; finish; }
started=$SECONDS
until screen_home "success-omarchy-update-restart-home" || (( SECONDS - started > 240 )); do sleep 5; done
check "and came back to home (OCR)" screen_home "success-omarchy-update-restart-home"
guest "journalctl --user -b -1 --no-pager -u agentv-screen" >"$RUN_DIR/screen-before.log" 2>&1 || true
check "through the screen daemon's Restart" grep -q "restarting the box from settings → power" "$RUN_DIR/screen-before.log"

# 4. Shut down from the TV: Settings → Power → Shut down, its question and
# its 10 s countdown, then the VM is off.
check "Settings opens at Power again" power_menu
sleep 2
for key in enter down enter; do
  guest "agentv input key $key" >>"$RUN_DIR/input.log" 2>&1 || true
  sleep 1
done
sleep 1
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
chosen=$SECONDS
while vm_running && (( SECONDS - chosen < 60 )); do sleep 0.5; done
if vm_running; then
  check "Shut down from the TV turned the box off on omarchy $want (still on after 60 s)" false
  stop_vm
else
  check "Shut down from the TV turned the box off on omarchy $want, $(( SECONDS - chosen )) s after it was chosen" true
fi
finish
