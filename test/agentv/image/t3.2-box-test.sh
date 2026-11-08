#!/bin/bash
#
# The box check on an installed box (T3.2), in QEMU. The daemon reads what
# the VM is: QEMU's model, its CPU and memory, virtio's GPU, which has no
# hardware video decoding and only software Vulkan, the disk, and the wired
# network. The package brings the tools it reads with. With the switch on,
# setup goes from getting ready to "here's your box", with those lines on
# the TV, and OK carries on to the location. QEMU's screen isn't 4K, so the
# 4K test doesn't run.

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
check "QEMU's screen isn't a 4K TV, and the VM is on a wire" jq -e '.verdicts.fourK == false and .verdicts.fourKSmooth == false and .network.kind == "ethernet"' "$RUN_DIR/box.json"
check "so the 4K test isn't asked for" until_json /api/box/smooth '.needed == false' 10
ssh_guest "bash -lc 'agentv box readings' </dev/null" >"$RUN_DIR/readings.json" 2>&1 || true
check "agentv box readings prints what it read" jq -e '.gpus | length >= 1' "$RUN_DIR/readings.json"

# --- Setup's box step, with its switch on ------------------------------------

# Switches turn on on edge only. Nothing updates during this check, so the
# box goes to edge by its channel file alone.
ssh_sudo "echo edge >/etc/agentv/channel"
ssh_guest "bash -lc 'agentv feature on boxcheck' </dev/null" >"$RUN_DIR/feature.log" 2>&1 || true
check "the box check's switch is on" until_json /api/features '.boxcheck == true' 10

setup_post /api/setup/finish '{"step": "welcome", "keyboard": true}'
setup_post /api/setup/ready '{"update": "none"}'
setup_post /api/setup/finish '{"step": "ready"}'
check "T3.2 setup's step after getting ready is your box" until_json /api/setup '.setup.step == "box"' 30
check "T3.2 the TV says here's your box (OCR)" ocr_finds success-T3.2-box "your box" 30
check "with the GPU's line (OCR)" ocr_finds success-T3.2-games "not for games" 10
capture_console "success-T3.2-box"

# One press of OK.
press ret
check "OK carries on to the location" until_json /api/setup '.setup.step == "country"' 30

stop_vm
finish
