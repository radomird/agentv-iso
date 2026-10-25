#!/bin/bash
#
# agentv selftest, the way Radomir runs it on the NUC, on the installed box:
# stage 0's S0.2 and S0.3, then stages 1 and 2, which it runs with no id:
# the TV session, the services' prompts off (S1.7), and what stage 2 can
# measure on the box (S2.8 to S2.16). The VM has no Wi-Fi card, so it gets
# the kernel's simulated one (mac80211_hwsim), which can be an access point
# the way the NUC's Intel card can. The NUC itself is still where S0.2,
# S0.3, S1.2, S1.5 and stage 2's timings pass: the VM has no Widevine,
# Steam, sound card or real screen.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-selftest-ssh-timeout || exit 1

# A throwaway VM: sudo without a password, set up the way upstream's own
# test/upgrade-test does, as someone at the box would type theirs.
ssh_sudo "printf '%s\n' '$GUEST_USER ALL=(ALL:ALL) NOPASSWD: ALL' 'Defaults:$GUEST_USER !authenticate' >/etc/sudoers.d/zzz-agentv-test && chmod 440 /etc/sudoers.d/zzz-agentv-test"

check "the VM gets a simulated Wi-Fi radio" ssh_sudo "modprobe mac80211_hwsim radios=1"
for _ in $(seq 1 30); do
  ssh_guest "nmcli -t -f TYPE device status | grep -qx wifi" && break
  sleep 2
done

# The welcome screen reports itself once it has drawn.
for _ in $(seq 1 60); do
  ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/health | jq -e .welcome_shown >/dev/null" && break
  sleep 2
done

ssh_guest "bash -lc 'agentv selftest S0.2 S0.3' </dev/null" >"$RUN_DIR/selftest.txt" 2>&1 || true
cat "$RUN_DIR/selftest.txt"

check "agentv selftest finds the root disk unencrypted" grep -q "^pass S0.2 the root disk isn't encrypted" "$RUN_DIR/selftest.txt"
check "agentv selftest finds the owner logged in on their own" grep -q "^pass S0.2 $GUEST_USER logs in on their own" "$RUN_DIR/selftest.txt"
check "agentv selftest finds the welcome screen shown" grep -q "^pass S0.2 the TV setup welcome screen was shown" "$RUN_DIR/selftest.txt"
check "agentv selftest finds a radio that can be an access point" grep -q "^pass S0.3 the Wi-Fi device can be an access point" "$RUN_DIR/selftest.txt"
check "agentv selftest brings up a WPA2 hotspot in AP mode" grep -q "^pass S0.3 NetworkManager brought up a WPA2 hotspot in AP mode" "$RUN_DIR/selftest.txt"
check "agentv selftest puts Wi-Fi back" grep -q "^pass S0.3 Wi-Fi is back as it was" "$RUN_DIR/selftest.txt"
check "agentv selftest leaves no hotspot behind" ssh_guest "! nmcli -g NAME connection show | grep -qx agentv-selftest-hotspot"
check "agentv selftest ends with every id passing" grep -qx "S0.2 pass, S0.3 pass" "$RUN_DIR/selftest.txt"

# Stage 2 measures the home screen itself, its tiles and UI sounds, so TV
# setup is marked done first, as it is on the NUC.
ssh_guest "bash -lc 'agentv setup skip' </dev/null" >"$RUN_DIR/setup.log" 2>&1 || true
for _ in $(seq 30); do
  [[ $(ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/health" 2>/dev/null | jq -r '.screen // ""' 2>/dev/null) == "home" ]] && break
  sleep 1
done
# The launcher's page takes the welcome page's place.
sleep 5

# Stages 1 and 2, as Radomir runs them over SSH while the TV is on.
ssh_guest "bash -lc 'agentv selftest' </dev/null" >"$RUN_DIR/selftest-stage1.txt" 2>&1 || true
cat "$RUN_DIR/selftest-stage1.txt"
stage1() {
  grep -qF "$1" "$RUN_DIR/selftest-stage1.txt"
}
# Stage 2 ends with S2.16, or S2.18 once Settings → Power is there (ADR-033).
check "agentv selftest with no id runs stages 1 and 2" \
  grep -qE "^S1.1 (pass|fail), .*S1.7 (pass|fail), S2.8 (pass|fail), .*S2.16 (pass|fail)(, S2.18 (pass|fail))?$" "$RUN_DIR/selftest-stage1.txt"
check "agentv selftest finds SDDM logging in to the TV session" stage1 "pass S1.1 SDDM logs $GUEST_USER in to the TV session"
check "agentv selftest finds the home screen in front" stage1 "pass S1.1 the TV session is on, with the home screen in front, full screen"
check "agentv selftest finds nothing of Omarchy's desktop" stage1 "pass S1.1 nothing of Omarchy's desktop runs in the TV session"
check "agentv selftest puts a web app in front" stage1 "pass S1.5 a web app came in front"
check "agentv selftest shows a toast over it" stage1 "pass S1.5 a toast showed over the app in front"
check "agentv selftest brings the home screen back" stage1 "pass S1.5 the home screen came back in front"
check "agentv selftest says what S1.2 and S1.5 leave for a person" \
  bash -c "grep -q '^manual S1.2 ' '$RUN_DIR/selftest-stage1.txt' && grep -q '^manual S1.5 ' '$RUN_DIR/selftest-stage1.txt'"
check "agentv selftest keeps a new window out of sight" stage1 "pass S1.6 a new window stayed out of sight"
check "agentv selftest finds the home screen back after a crash" stage1 "pass S1.6 the home screen came back in front"
check "agentv selftest finds the services' Chromium with its prompts off (S1.7)" stage1 "pass S1.7 the services' Chromium has saving passwords"
check "agentv selftest finds a key reaching the home screen (S2.9)" stage1 "pass S2.9 a key on the virtual input device reaches the home screen"
check "agentv selftest measures frames while the focus moves and a page slides (S2.10)" \
  grep -qE "^(pass|fail) S2.10 with the focus gliding.*drew at" "$RUN_DIR/selftest-stage1.txt"
check "agentv selftest measures each UI sound after its key (S2.11)" \
  grep -qE "^(pass|fail) S2.11 (each UI sound started within|a UI sound started)" "$RUN_DIR/selftest-stage1.txt"
check "agentv selftest finds the move sound held to one every 60 ms (S2.11)" stage1 "pass S2.11 a held arrow played a move sound at most every 60 ms"
check "agentv selftest times Home (S2.15)" stage1 "pass S2.15 Home put the home screen in front in"
check "agentv selftest times choosing the app again (S2.15)" stage1 "pass S2.15 choosing the app again brought the same window back in"
check "agentv selftest says what stage 2 leaves for a person" \
  bash -c "for id in S1.7 S2.8 S2.9 S2.10 S2.11 S2.15 S2.16; do grep -q \"^manual \$id \" '$RUN_DIR/selftest-stage1.txt' || exit 1; done"
check "agentv selftest never stops halfway" bash -c "! grep -q 'the selftest stopped' '$RUN_DIR/selftest-stage1.txt'"

stop_vm
finish
