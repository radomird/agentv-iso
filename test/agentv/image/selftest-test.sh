#!/bin/bash
#
# agentv selftest, the way Radomir runs it on the NUC for S0.2 and S0.3, on
# the installed box. The VM has no Wi-Fi card, so it gets the kernel's
# simulated one (mac80211_hwsim), which can be an access point the way the
# NUC's Intel card can. The NUC itself is still where S0.2 and S0.3 pass.

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

ssh_guest "bash -lc 'agentv selftest' </dev/null" >"$RUN_DIR/selftest.txt" 2>&1 || true
cat "$RUN_DIR/selftest.txt"

check "agentv selftest finds the root disk unencrypted" grep -q "^pass S0.2 the root disk isn't encrypted" "$RUN_DIR/selftest.txt"
check "agentv selftest finds the owner logged in on their own" grep -q "^pass S0.2 $GUEST_USER logs in on their own" "$RUN_DIR/selftest.txt"
check "agentv selftest finds the welcome screen shown" grep -q "^pass S0.2 the TV setup welcome screen was shown" "$RUN_DIR/selftest.txt"
check "agentv selftest finds a radio that can be an access point" grep -q "^pass S0.3 the Wi-Fi device can be an access point" "$RUN_DIR/selftest.txt"
check "agentv selftest brings up a WPA2 hotspot in AP mode" grep -q "^pass S0.3 NetworkManager brought up a WPA2 hotspot in AP mode" "$RUN_DIR/selftest.txt"
check "agentv selftest puts Wi-Fi back" grep -q "^pass S0.3 Wi-Fi is back as it was" "$RUN_DIR/selftest.txt"
check "agentv selftest leaves no hotspot behind" ssh_guest "! nmcli -g NAME connection show | grep -qx agentv-selftest-hotspot"
check "agentv selftest ends with every id passing" grep -qx "S0.2 pass, S0.3 pass" "$RUN_DIR/selftest.txt"

stop_vm
finish
