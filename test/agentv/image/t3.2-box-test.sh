#!/bin/bash
#
# The box check on an installed box (T3.2), in QEMU. The daemon reads what
# the VM is: QEMU's model, its CPU and memory, virtio's GPU, which has no
# hardware video decoding and only software Vulkan, the disk, and the wired
# network. The package brings the tools it reads with. With the switch on,
# setup goes from getting ready to "here's your box", with those lines on
# the TV, and OK carries on to the location.
#
# QEMU's virtual monitor has an EDID that lists modes up to 3840 x 2160 and
# wider, so the box counts it as a 4K TV, and the 4K test is wanted. But
# QEMU draws the TV at 1280 x 800, so the test doesn't run: the box step
# says 4K isn't checked yet, as on a 4K TV shown at a lower mode.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-T3.2-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-T3.2-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

daemon_get() {
  ssh_guest "curl -fsS --max-time 30 http://127.0.0.1:3000$1" 2>/dev/null
}
setup_post() {
  ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '$2' http://127.0.0.1:3000$1" >>"$RUN_DIR/setup-posts.log" 2>&1
}
until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(daemon_get "$1" | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 1
}

# --- What the box is -------------------------------------------------------

check "the package brings vainfo and vulkaninfo, and pci.ids names GPUs" ssh_guest "command -v vainfo && command -v vulkaninfo && test -s /usr/share/hwdata/pci.ids"

daemon_get /api/box >"$RUN_DIR/box.json" || true
log "The box check: $(jq -c . "$RUN_DIR/box.json" 2>/dev/null)"
check "T3.2 /api/box answers in the plan's shape" jq -e 'keys_unsorted == ["model", "cpu", "memoryGb", "storage", "gpu", "tv", "network", "bluetooth", "gamepads", "widevine", "verdicts"]' "$RUN_DIR/box.json"
check "T3.2 it has the VM's model, CPU, memory and disk" jq -e '(.model | test("QEMU|Standard PC")) and .cpu.threads >= 1 and (.cpu.name | length) > 0 and .memoryGb >= 2 and .storage.totalGb > 0 and .storage.freeGb > 0' "$RUN_DIR/box.json"
check "T3.2 virtio's GPU decodes nothing in hardware and isn't for games" jq -e '.gpu.vendor == "other" and .gpu.decode == [] and .verdicts.games == "none"' "$RUN_DIR/box.json"
check "T3.2 QEMU's monitor reads as a 4K TV from its EDID, not checked for 4K yet, and the VM is on a wire" jq -e '.tv.name == "QEMU Monitor" and (.tv.modes | index("3840x2160@60")) != null and .verdicts.fourK == true and .verdicts.fourKSmooth == false and .network.kind == "ethernet"' "$RUN_DIR/box.json"
check "so the 4K test is wanted, with no result yet" until_json /api/box/smooth '.needed == true and .result == null' 10
ssh_guest "bash -lc 'agentv box readings' </dev/null" >"$RUN_DIR/readings.json" 2>&1 || true
check "agentv box readings prints what it read" jq -e '.gpus | length >= 1' "$RUN_DIR/readings.json"

# --- Setup's box step, with its switch on ------------------------------------

# The box check's switch is on, as every box has it.
check "the box check's switch is on" until_json /api/features '.boxcheck == true' 10

setup_post /api/setup/finish '{"step": "welcome", "keyboard": true}'
setup_post /api/setup/ready '{"update": "none"}'
setup_post /api/setup/finish '{"step": "ready"}'
check "T3.2 setup's step after getting ready is your box" until_json /api/setup '.setup.step == "box"' 30
# "Here's your setup", or "here's your box" on a release before the words
# changed.
check "T3.2 the TV says here's your setup (OCR)" ocr_finds success-T3.2-box "your setup|your box" 30
check "with the GPU's line (OCR)" ocr_finds success-T3.2-games "not for games" 10
# The TV runs at its full resolution, so the 4K test runs at QEMU's 4K mode
# on the step itself, where virtio's GPU can't keep it smooth.
check "the 4K test ran at the TV's 4K mode, and the box didn't keep it smooth" until_json /api/box/smooth '.result.width == 3840 and .passed == false' 30
check "and the computer's line says it's better at 1080p (OCR)" ocr_finds success-T3.2-smooth "better at 1080p|smoother at 1080p" 15
capture_console "success-T3.2-box"

# One press of OK.
press ret
check "OK carries on to the location" until_json /api/setup '.setup.step == "country"' 30

stop_vm
finish
