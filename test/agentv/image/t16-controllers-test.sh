#!/bin/bash
#
# Controllers in Settings on an installed box (ADR-084, T16.1), in QEMU. A VM
# has no Bluetooth radio, and there's none to stand in for cheaply, so this
# checks what the page needs of the box, and what it says without a radio:
#   - BlueZ and its tools are on the box, and bluetooth.service is enabled,
#     as Omarchy leaves it;
#   - the daemon's routes reach the TV session and back, and say the TV has
#     no Bluetooth;
#   - Settings, controllers says so on the TV, in one line;
#   - with BlueZ started by hand (the kernel's Bluetooth module, and still
#     no radio), the TV's owner can ask it what it has, with no sudo, and
#     the answer is in the shape the daemon reads;
#   - pairing is refused without an adapter, and an address that isn't one
#     never gets as far as the TV session.
# Finding, pairing and removing a real controller are the NUC's.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-T16-controllers-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-T16-controllers-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
wait_home 60 >/dev/null || true

# The Nightly's edge leg runs this on edge's last build, which may be from
# before the page, so on a box without it this waits.
if ! ssh_guest "test -f /usr/share/agentv/daemon/controllers.ts"; then
  log "This agentv has no controllers page yet ($(guest "agentv version" 2>/dev/null | head -n 1)); T16.1 waits for it"
  stop_vm
  finish
  exit 0
fi

controllers() {
  ssh_guest "curl -sS --max-time 30 $1 http://127.0.0.1:3000/api/controllers$2" 2>/dev/null
}

# --- What the page needs of the box ------------------------------------------

check "BlueZ's tools and busctl are on the box" ssh_guest "command -v bluetoothctl && command -v busctl && command -v rfkill"
check "bluetooth.service is enabled, as Omarchy leaves it" test "$(ssh_guest "systemctl is-enabled bluetooth.service" 2>/dev/null)" = "enabled"
check "the package has the page, its routes and what drives BlueZ" ssh_guest "test -f /usr/share/agentv/launcher/pages/controllers.ts && test -f /usr/share/agentv/daemon/routes/controllers.ts"

# --- A box with no Bluetooth ---------------------------------------------------

controllers "" "" >"$RUN_DIR/controllers.json" || true
log "Controllers: $(jq -c . "$RUN_DIR/controllers.json" 2>/dev/null)"
check "T16.1 the TV session answers, and says the box has no Bluetooth" jq -e '.ok == true and .bluetooth == "none" and .controllers == [] and .looking == false' "$RUN_DIR/controllers.json"
check "and the box check agrees" test "$(ssh_guest "curl -fsS --max-time 30 http://127.0.0.1:3000/api/box" 2>/dev/null | jq -r '"\(.bluetooth) \(.gamepads)"')" = "false 0"

guest "agentv screen settings controllers" >"$RUN_DIR/settings.json" 2>&1 || true
check "T16.1 Settings, controllers says the TV has no Bluetooth (OCR)" ocr_finds success-T16-controllers-none "no bluetooth" 30
capture_console "success-T16-controllers-none"

controllers "-X POST -H 'Content-Type: application/json' -d '{\"on\": true}'" /look >"$RUN_DIR/look.json" || true
check "looking for controllers starts nothing without a radio" jq -e '.bluetooth == "none" and .looking == false' "$RUN_DIR/look.json"
check "and no bluetoothctl is left running" test -z "$(ssh_guest "pgrep -x bluetoothctl" 2>/dev/null)"

controllers "-X POST -H 'Content-Type: application/json' -d '{\"id\": \"AC:8E:BD:11:22:33\"}'" /pair >"$RUN_DIR/pair.json" || true
check "pairing is refused: there's no adapter" jq -e '.ok == false and .why == "none"' "$RUN_DIR/pair.json"
controllers "-X POST -H 'Content-Type: application/json' -d '{\"id\": \"/org/bluez/hci0\"}'" /pair >"$RUN_DIR/pair-bad.json" || true
check "and what isn't a controller's address is turned away" jq -e '.ok == false and (.error | test("controller from the list"))' "$RUN_DIR/pair-bad.json"

# --- BlueZ itself, as the TV's owner --------------------------------------------

# bluetooth.service only starts on a box with Bluetooth. The kernel's module
# makes /sys/class/bluetooth without a radio, which is enough for BlueZ to
# run and answer with no adapter.
ssh_guest "sudo modprobe bluetooth && sudo systemctl start bluetooth.service" >"$RUN_DIR/bluez-start.log" 2>&1 || true
check "BlueZ runs once the kernel has Bluetooth" test "$(ssh_guest "systemctl is-active bluetooth.service" 2>/dev/null)" = "active"
ssh_guest "busctl --system --no-pager --timeout=45 --json=short call org.bluez / org.freedesktop.DBus.ObjectManager GetManagedObjects" >"$RUN_DIR/objects.json" 2>"$RUN_DIR/objects.err" || true
log "BlueZ's objects: $(head -c 600 "$RUN_DIR/objects.json")"
check "T16.1 the TV's owner can ask BlueZ what it has, with no sudo, in the shape the daemon reads" jq -e '.type == "a{oa{sa{sv}}}" and (.data[0]["/org/bluez"] | has("org.bluez.AgentManager1"))' "$RUN_DIR/objects.json"
check "BlueZ's D-Bus policy lets anyone on the box talk to it, which the owner's pairing relies on" ssh_guest "grep -q 'send_destination=\"org.bluez\"' /usr/share/dbus-1/system.d/bluetooth.conf"
controllers "" "" >"$RUN_DIR/controllers-bluez.json" || true
check "with BlueZ running and no radio, the page's answer is still no Bluetooth" jq -e '.ok == true and .bluetooth == "none"' "$RUN_DIR/controllers-bluez.json"

stop_vm
finish
