#!/bin/bash
#
# The built-in Music app on an installed box (S3.6): an album in ~/Music, a
# USB stick plugged in while the TV is on, and a NAS share served from the
# test container, then agentv selftest S3.6, which reads them all again and
# plays the stick's album and the share's, each found by its name. The stick
# goes in through QEMU's monitor and mounts through udisks2; the share is
# SMB, served by impacket and mounted through gvfs, the way a real NAS is.
# The VM has no sound card, so this shows the music plays, not that it's
# heard: the NUC's manual line is for that.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

work=$(mktemp -d)
smb=""
# The share and the files go too, before upstream's own cleanup, which keeps
# the exit status.
stop_share() {
  local status=$?
  [[ -n $smb ]] && kill "$smb" 2>/dev/null
  rm -rf "$work"
  (exit "$status")
  cleanup
}
trap stop_share EXIT

# album <folder> <name>: two short tones as WAV files, named the way a ripped
# album is. They have no tags, so Music takes the album from the folder and
# each title from its file.
album() {
  mkdir -p "$1/$2"
  python3 - "$1/$2" <<'PY'
import math, struct, sys, wave
for number, (name, hz) in enumerate([("Dusk", 440), ("Dawn", 660)], 1):
    with wave.open(f"{sys.argv[1]}/{number:02d} {name}.wav", "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(22050)
        out.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * hz * i / 22050))) for i in range(22050 * 20)))
PY
}

album "$work/folder" "Test Tones"
album "$work/stick" "Night Shift"
album "$work/share" "Harbour Lights"

# The stick: a FAT image, as most sticks come.
mkfs.fat -C -n STICK "$work/stick.img" 65536 >/dev/null
mcopy -s -i "$work/stick.img" "$work/stick/Night Shift" ::

# The share: SMB on port 445 of this container, which the VM reaches as
# 10.0.2.2, with guest access, as many home NASes have.
python=python3
if ! pacman -S --noconfirm --needed impacket >/dev/null 2>&1 || ! python3 -c "import impacket" 2>/dev/null; then
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q impacket==0.13.1 >/dev/null 2>&1
  python="$work/venv/bin/python"
fi
"$python" - "$work/share" >"$work/smb.log" 2>&1 <<'PY' &
import sys
from impacket import smbserver
server = smbserver.SimpleSMBServer(listenAddress="0.0.0.0", listenPort=445)
server.addShare("MUSIC", sys.argv[1], "music")
server.setSMB2Support(True)
server.setSMBChallenge("")
server.start()
PY
smb=$!

start_vm_from_base
wait_for_ssh 300 failure-music-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-music-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

check "the test container serves the share" kill -0 "$smb"

# The album in the person's own Music folder.
tar -C "$work/folder" -c . | ssh_guest "mkdir -p ~/Music && tar -C ~/Music -x"

# The stick, plugged in now.
qmp "\"blockdev-add\", \"arguments\": {\"node-name\": \"stick\", \"driver\": \"raw\", \"file\": {\"driver\": \"file\", \"filename\": \"$work/stick.img\"}}" >"$RUN_DIR/qmp.log"
qmp '"device_add", "arguments": {"driver": "usb-storage", "id": "stick0", "drive": "stick", "removable": true}' >>"$RUN_DIR/qmp.log"
plugged=0
for _ in $(seq 1 60); do
  if guest "lsblk -J -o PATH,TRAN,LABEL" 2>/dev/null | jq -e '.. | objects | select(.label? == "STICK")' >/dev/null 2>&1; then
    plugged=1
    break
  fi
  sleep 0.5
done
check "the box sees the stick" test "$plugged" = 1

guest "agentv music add-share smb://10.0.2.2/music" >"$RUN_DIR/add-share.json" 2>&1 || true
cat "$RUN_DIR/add-share.json"
check "Music adds the share, mounted through gvfs" jq -e '.ok == true and .source.available == true' "$RUN_DIR/add-share.json"

guest "agentv selftest S3.6" >"$RUN_DIR/selftest.txt" 2>&1 || true
cat "$RUN_DIR/selftest.txt"
check "S3.6 play finds the stick's album, and it plays" grep -q "^pass S3.6 play Night Shift found the album on a USB drive" "$RUN_DIR/selftest.txt"
check "S3.6 play finds the share's album, and it plays" grep -q "^pass S3.6 play Harbour Lights found the album on a NAS share (smb://10.0.2.2/music)" "$RUN_DIR/selftest.txt"

guest "agentv music library" >"$RUN_DIR/library.json" 2>&1 || true
check "the library has the folder's album too, with its tracks from their file names" \
  jq -e '[.albums[] | select(.title == "Test Tones" and (.source | startswith("folder:")) and (.tracks | length) == 2)] | length == 1' "$RUN_DIR/library.json"
check "and the stick's album from udisks2's mount" \
  jq -e '[.albums[] | select(.title == "Night Shift" and (.source | startswith("usb:")))] | length == 1' "$RUN_DIR/library.json"
check "what played went to the ledger as tracks" \
  test "$(ssh_guest "curl -fsS --max-time 3 'http://127.0.0.1:3000/api/ledger?app=agentv.music'" | jq '[.rows[] | select(.kind == "track")] | length')" -ge 1
check "the music stopped after" test "$(guest "agentv music now" 2>/dev/null | jq -r '.now')" = "null"

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen.log" 2>&1 || true
cp "$work/smb.log" "$RUN_DIR/smb.log" 2>/dev/null || true
stop_vm
finish
