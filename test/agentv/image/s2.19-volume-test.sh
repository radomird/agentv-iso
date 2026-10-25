#!/bin/bash
#
# S2.19: the box plays at full volume, and the TV's remote sets how loud it
# is. The VM gets a sound card the box hasn't seen before (QEMU's Intel HDA,
# playing to nothing), and its output must be the default at 100%. A level
# set the way Settings → Sound's volume row sets it must still be there after
# a restart, and agentv selftest S2.19 must say so.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# start_vm_from_base, with a sound card.
qemu-img create -f qcow2 -b "$BASE_DISK" -F qcow2 "$RUN_DIR/run.qcow2" >/dev/null
cp "$BASE_OVMF" "$RUN_DIR/OVMF_VARS.4m.fd"
# shellcheck disable=SC2034 # start_vm reads it
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/serial.log" -audiodev none,id=snd0 -device intel-hda -device hda-output,audiodev=snd0
wait_for_ssh 300 failure-S2.19-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-S2.19-no-tv"; check "the TV session came up" false; stop_vm; finish; }

audio() {
  guest "agentv screen audio" 2>/dev/null || true
}

# until_audio <jq filter> <seconds>: until the screen daemon's answer passes
# it, giving PipeWire and the screen daemon time to settle.
until_audio() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    jq -e "$1" <<<"$(audio)" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

until_audio '.output // "" | startswith("alsa_output.")' 60 || true
audio >"$RUN_DIR/audio.json"
cat "$RUN_DIR/audio.json"
check "the sound card's output is the default" jq -e '.output // "" | startswith("alsa_output.")' "$RUN_DIR/audio.json"
check "S2.19 a new box's default output plays at 100%" until_audio '.volume == 1 and .expected == 1' 30
guest "pactl get-sink-volume @DEFAULT_SINK@" >"$RUN_DIR/pactl.txt" 2>&1 || true
cat "$RUN_DIR/pactl.txt"
check "and PipeWire says 100% too" grep -q " 100% " "$RUN_DIR/pactl.txt"
check "WirePlumber starts new outputs at full volume" \
  ssh_guest "grep -q 'device.routes.default-sink-volume = 1.0' ~/.config/wireplumber/wireplumber.conf.d/50-agentv-volume.conf"

# Settings → Sound's volume row, as agentv screen audio sets it.
guest "agentv screen audio volume 60" >"$RUN_DIR/set.json" 2>&1 || true
cat "$RUN_DIR/set.json"
check "the volume set in Settings is 60%" jq -e '.ok and .volume == 0.6 and .expected == 0.6' "$RUN_DIR/set.json"

boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
log "Restarting the box"
ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
started=$SECONDS
while [[ $(ssh_guest "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || echo "$boot") == "$boot" ]] && (( SECONDS - started < 120 )); do sleep 3; done
wait_for_ssh 300 failure-S2.19-reboot-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
check "the box restarted" test "$(ssh_guest "cat /proc/sys/kernel/random/boot_id")" != "$boot"

until_audio '.volume == 0.6' 60 || true
audio >"$RUN_DIR/audio-after.json"
cat "$RUN_DIR/audio-after.json"
check "S2.19 after a restart, the output keeps the 60% chosen in Settings" jq -e '.volume == 0.6 and .expected == 0.6' "$RUN_DIR/audio-after.json"
guest "agentv selftest S2.19" >"$RUN_DIR/selftest.txt" 2>&1 || true
cat "$RUN_DIR/selftest.txt"
check "agentv selftest S2.19 says so" grep -q "^pass S2.19 .* plays at 60%, as chosen in Settings → Sound" "$RUN_DIR/selftest.txt"
guest "journalctl --user -b -1 --no-pager -u agentv-screen" 2>/dev/null | grep "sound:" >"$RUN_DIR/sound.log" || true
cat "$RUN_DIR/sound.log"

stop_vm
finish
