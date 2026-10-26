#!/bin/bash
#
# The built-in Music app on an installed box (S3.6): an album in ~/Music, a
# USB stick plugged in while the TV is on, and two NAS shares served by Samba
# from the test container, then agentv selftest S3.6, which reads them all
# again and plays the stick's album and a share's, each found by its name.
# The stick goes in through QEMU's monitor and mounts through udisks2. One
# share takes guests and mounts through gvfs, as before; the other has a
# password, which root keeps and mounts the share with, read-only, and
# again after the box restarts (ADR-038). The VM has no sound card, so this
# shows the music plays, not that it's heard: the NUC's manual line is for
# that.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

work=$(mktemp -d)
# Samba runs as a daemon, in a session of its own: in the foreground it shared
# this check's process group, and it stops its whole group as it goes. Its
# pid file is named after the config file when that isn't the default one.
smb_pid() {
  cat "$work"/samba/run/smbd*.pid 2>/dev/null | head -n 1
}
# The share and the files go too, before upstream's own cleanup, which keeps
# the exit status.
stop_share() {
  local status=$? pid
  pid=$(smb_pid)
  if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; fi
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
album "$work/private" "Quiet Rooms"
# A password with a comma, spaces and an equals sign, as mount options
# would read wrongly.
SHARE_PASSWORD="tunes, at 9 = fine"

# The stick: a FAT image, as most sticks come.
mkfs.fat -C -n STICK "$work/stick.img" 65536 >/dev/null
mcopy -s -i "$work/stick.img" "$work/stick/Night Shift" ::

# The shares: Samba on port 445 of this container, which the VM reaches as
# 10.0.2.2. "music" takes guests, as many home NASes do; "private" only takes
# the user tv, with its password, read-only.
pacman -S --noconfirm --needed samba >"$work/samba-install.log" 2>&1 || { cat "$work/samba-install.log"; check "Samba installs in the test container" false; finish; }
id tv >/dev/null 2>&1 || useradd -M -s /usr/bin/nologin tv
mkdir -p "$work/samba/private" "$work/samba/lock" "$work/samba/state" "$work/samba/cache" "$work/samba/run" "$work/samba/ncalrpc" "$work/samba/log"
# Samba reads the files as the guest or as tv.
chmod -R a+rX "$work"
cat >"$work/smb.conf" <<CONF
[global]
  server role = standalone server
  workgroup = WORKGROUP
  smb ports = 445
  disable netbios = yes
  server min protocol = SMB2
  map to guest = Bad User
  guest account = nobody
  passdb backend = tdbsam:$work/samba/private/passdb.tdb
  private dir = $work/samba/private
  lock directory = $work/samba/lock
  state directory = $work/samba/state
  cache directory = $work/samba/cache
  pid directory = $work/samba/run
  ncalrpc dir = $work/samba/ncalrpc
  load printers = no
  printing = bsd
  printcap name = /dev/null
  disable spoolss = yes
[music]
  path = $work/share
  guest ok = yes
  read only = yes
[private]
  path = $work/private
  valid users = tv
  read only = yes
CONF
printf '%s\n%s\n' "$SHARE_PASSWORD" "$SHARE_PASSWORD" | smbpasswd -c "$work/smb.conf" -s -a tv >/dev/null
smbd --daemon -s "$work/smb.conf" -l "$work/samba/log"
# smbd up: its pid written, and still there.
smb_up() {
  local pid
  pid=$(smb_pid)
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}

start_vm_from_base
wait_for_ssh 300 failure-music-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-music-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

check "the test container serves the share" smb_up
smb_up || tail -n 30 "$work/samba/log/log.smbd" 2>/dev/null

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

# ADR-038: the share with a password, typed on stdin as over SSH. One the NAS
# turns down says so, and isn't kept.
printf 'not-it\n' | ssh_guest "bash -lc 'agentv music add-share smb://tv@10.0.2.2/private'" >"$RUN_DIR/add-wrong.json" 2>&1 || true
cat "$RUN_DIR/add-wrong.json"
check "ADR-038 a password the NAS turns down says so" \
  jq -e '.ok == false and .error == "the NAS didn'"'"'t take that user name and password"' "$RUN_DIR/add-wrong.json"
printf '%s\n' "$SHARE_PASSWORD" | ssh_guest "bash -lc 'agentv music add-share smb://tv@10.0.2.2/private'" >"$RUN_DIR/add-private.json" 2>&1 || true
cat "$RUN_DIR/add-private.json"
check "ADR-038 Music adds the share with a password, mounted by root under /mnt/agentv" \
  jq -e '.ok == true and .source.available == true and (.source.path | startswith("/mnt/agentv/"))' "$RUN_DIR/add-private.json"
point=$(jq -r '.source.path // "/mnt/agentv/none"' "$RUN_DIR/add-private.json" 2>/dev/null || echo /mnt/agentv/none)
check "ADR-038 it's a CIFS mount, read-only" ssh_guest "findmnt -n -o FSTYPE,OPTIONS '$point' | grep -Eq '^cifs +ro(,|\$)'"
check "ADR-038 the person at the TV can't read its password" ssh_guest "! ls /etc/agentv/shares/ 2>/dev/null"
check "ADR-038 root keeps it, in a file only root can read" \
  ssh_sudo "set -o pipefail; test \"\$(stat -c %a /etc/agentv/shares/*.cred)\" = 600 && grep -qxF 'password=$SHARE_PASSWORD' /etc/agentv/shares/*.cred"
check "ADR-038 and the password is in nothing the TV session keeps" \
  ssh_guest "! grep -rqF '$SHARE_PASSWORD' ~/.local/state/agentv /etc/agentv/shares.json"

guest "agentv selftest S3.6" >"$RUN_DIR/selftest.txt" 2>&1 || true
cat "$RUN_DIR/selftest.txt"
check "S3.6 play finds the stick's album, and it plays" grep -q "^pass S3.6 play Night Shift found the album on a USB drive" "$RUN_DIR/selftest.txt"
check "S3.6 play finds the share's album, and it plays" grep -q "^pass S3.6 play Harbour Lights found the album on a NAS share (smb://10.0.2.2/music)" "$RUN_DIR/selftest.txt"

guest "agentv music library" >"$RUN_DIR/library.json" 2>&1 || true
check "the library has the folder's album too, with its tracks from their file names" \
  jq -e '[.albums[] | select(.title == "Test Tones" and (.source | startswith("folder:")) and (.tracks | length) == 2)] | length == 1' "$RUN_DIR/library.json"
check "and the stick's album from udisks2's mount" \
  jq -e '[.albums[] | select(.title == "Night Shift" and (.source | startswith("usb:")))] | length == 1' "$RUN_DIR/library.json"
check "ADR-038 and the album on the share with a password, from root's mount" \
  jq -e '[.albums[] | select(.title == "Quiet Rooms" and .source == "share:smb://tv@10.0.2.2/private" and .away != true)] | length == 1' "$RUN_DIR/library.json"
check "what played went to the ledger as tracks" \
  test "$(ssh_guest "curl -fsS --max-time 3 'http://127.0.0.1:3000/api/ledger?app=agentv.music'" | jq '[.rows[] | select(.kind == "track")] | length')" -ge 1
check "the music stopped after" test "$(guest "agentv music now" 2>/dev/null | jq -r '.now')" = "null"

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen.log" 2>&1 || true

# ADR-038: after a restart, the share with a password is back with no one
# asked, and so is its album.
log "Restarting the box: the share with a password comes back on its own"
boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
started=$SECONDS
while [[ $(ssh_guest "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || echo "$boot") == "$boot" ]] && (( SECONDS - started < 120 )); do sleep 3; done
wait_for_ssh 300 failure-music-reboot-ssh-timeout || exit 1
check "the box restarted" test "$(ssh_guest "cat /proc/sys/kernel/random/boot_id")" != "$boot"
took=$(wait_home 240) || took="over 240"
log "Home was in front $took s after SSH answered"
mounted_again() {
  local started=$SECONDS
  while (( SECONDS - started < 120 )); do
    ssh_guest "findmnt -n -o FSTYPE '$point' | grep -qx cifs" && return 0
    sleep 2
  done
  return 1
}
check "ADR-038 after a restart the share with a password is mounted again" mounted_again
ssh_sudo "journalctl -b --no-pager -u agentv-shares -u agentv-share" >"$RUN_DIR/shares.log" 2>&1 || true
guest "agentv music scan --wait" >"$RUN_DIR/scan-after-restart.json" 2>&1 || true
guest "agentv music library" >"$RUN_DIR/library-after-restart.json" 2>&1 || true
check "ADR-038 and its album is in the library, and not away" \
  jq -e '[.albums[] | select(.title == "Quiet Rooms" and .away != true)] | length == 1' "$RUN_DIR/library-after-restart.json"
guest "agentv music sources" >"$RUN_DIR/sources-after-restart.json" 2>&1 || true
check "and Music → sources says it's ready" \
  jq -e '[.sources[] | select(.id == "share:smb://tv@10.0.2.2/private" and .available == true)] | length == 1' "$RUN_DIR/sources-after-restart.json"

cp "$work/samba/log/log.smbd" "$RUN_DIR/smb.log" 2>/dev/null || true
stop_vm
finish
