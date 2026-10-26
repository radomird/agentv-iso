#!/bin/bash
#
# Updates from the TV (ADR-025, S2.12): Settings → Updates' Check now finds the
# newer agentv the image run hands over, and Install now installs it, with the
# TV's Updating screen on while it runs, then home again on the new release.
# The update ends by restarting AgenTV's own services (agentv-restart), so
# the daemon, the screen daemon and home run the new agentv with no restart
# of the box, unless it has a new kernel or Omarchy's update says it needs one.
# Both go through the TV's screen daemon, as the launcher's buttons do
# (agentv screen update check|install), and through polkit. Skips when
# there's no newer agentv, as S0.5 does.
#
# Then Go back (S2.14): the update "breaks" a small app of the box's own, the
# check after it finds it, the TV says something's off, and Go back on it
# restarts the box into the snapshot from before the update, on the agentv
# it had and with the app whole again, with no reinstall.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

if [[ -z ${AGENTV_TEST_UPDATE_REPO:-} ]]; then
  log "No newer agentv to update to; skipping"
  exit 0
fi
base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

port=$((SSH_PORT + 3))
# The repository, with each package taking about 20 s to come down, as on a
# slow line: an update of one small package is otherwise over before the
# check can read the Updating screen. pacman gives up on a download only when
# nothing comes for 10 s.
(cd "$AGENTV_TEST_UPDATE_REPO" && exec python3 - "$port" <<'PY'
import http.server, os, sys, time

class Slow(http.server.SimpleHTTPRequestHandler):
    def copyfile(self, source, outputfile):
        if not self.path.endswith(".pkg.tar.zst"):
            return super().copyfile(source, outputfile)
        size = os.fstat(source.fileno()).st_size
        while data := source.read(max(1, size // 40)):
            outputfile.write(data)
            outputfile.flush()
            time.sleep(0.5)

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Slow).serve_forever()
PY
) >/dev/null 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

start_vm_from_base
wait_for_ssh 300 failure-update-tv-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
ssh_sudo "install -d /etc/agentv && echo http://10.0.2.2:$port >/etc/agentv/repository"
before=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
kernel=$(ssh_guest "uname -r")
boot_id=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")

# A small app made on this box, which the check after the update loads. It's
# there before the update, so the snapshot has it.
ssh_guest "cat >/tmp/clock.sh" <<'SH'
set -e
dir=/var/lib/agentv/apps/local.clock
install -d -m 755 "$dir"
cat >"$dir/manifest.json" <<'JSON'
{
  "schemaVersion": 1,
  "id": "local.clock",
  "name": "Clock",
  "version": "1.0.0",
  "author": "me",
  "license": "MIT",
  "description": "A clock made on this box, for AgenTV's image checks",
  "kinds": ["tv-app"],
  "entryPoints": { "tvApp": "app.ts" },
  "tv": {
    "contract": 1,
    "category": "utility",
    "runtime": "web",
    "homeUrl": "http://127.0.0.1:8765/",
    "origins": ["http://127.0.0.1:8765"],
    "capabilities": ["launch"],
    "childSafe": true
  }
}
JSON
printf '%s\n' 'export default {' '  id: "local.clock",' '  async launch() {},' '};' >"$dir/app.ts"
record=/var/lib/agentv/apps/installed.json
[ -f "$record" ] || echo '{}' >"$record"
jq '. + {"local.clock": {id: "local.clock", name: "Clock", version: "1.0.0", tier: "local", installedAt: "2026-10-23T12:00:00Z"}}' "$record" >"$record.new"
mv "$record.new" "$record"
chmod 644 "$dir/manifest.json" "$dir/app.ts" "$record"
SH
ssh_sudo "bash /tmp/clock.sh" >"$RUN_DIR/clock.log" 2>&1 || true
check "a small app of the box's own is installed" \
  ssh_guest "curl -fsS http://127.0.0.1:3000/api/home | jq -e '[.apps[].id] | index(\"local.clock\")'"

# until_file <jq filter> <file> <seconds>: until the filter is true.
until_file() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "cat $2 2>/dev/null" | jq -r "$1" 2>/dev/null) == "true" ]] && return 0
    sleep 3
  done
  return 1
}

# The agentv this run hands over isn't in the nightly run's tested.json, so
# on stable it waits (ADR-026), and Check now says so. On edge, where this
# run's packages put the box, it goes ahead, the way S0.5's check takes it
# with --untested.
ssh_sudo "echo stable >/etc/agentv/channel"
guest "agentv screen update check" >"$RUN_DIR/screen.log" 2>&1 || true
check "S2.12 on stable, Check now says agentv $AGENTV_TEST_UPDATE_VERSION waits for the nightly run" \
  until_file ".channel == \"stable\" and .agentv.available == \"$AGENTV_TEST_UPDATE_VERSION\" and .waiting == true" /var/lib/agentv/update/status.json 180
ssh_sudo "echo edge >/etc/agentv/channel"
guest "agentv screen update check" >>"$RUN_DIR/screen.log" 2>&1 || true
check "S2.12 Check now finds agentv $AGENTV_TEST_UPDATE_VERSION" \
  until_file ".channel == \"edge\" and .agentv.available == \"$AGENTV_TEST_UPDATE_VERSION\" and .waiting == false" /var/lib/agentv/update/status.json 180
ssh_guest "cat /var/lib/agentv/update/status.json" >"$RUN_DIR/status.json" 2>&1 || true
check "S2.12 and says which agentv the box has now" \
  test "$(jq -r '.agentv.installed' "$RUN_DIR/status.json")" = "$before"

guest "agentv screen update install" >>"$RUN_DIR/screen.log" 2>&1 || true
check "S2.12 Install now starts the update" \
  until_file '.state == "running"' /var/lib/agentv/update/progress.json 60
sleep 5
ocr_screen >"$RUN_DIR/success-update-tv-updating.txt" 2>/dev/null || true
capture_console "success-update-tv-updating"
check "S2.12 the TV shows the Updating screen (OCR)" grep -qi "updating to agentv" "$RUN_DIR/success-update-tv-updating.txt"

log "Waiting for the update to finish"
until_file '.state != "running"' /var/lib/agentv/update/progress.json 2400 || true
ssh_guest "cat /var/lib/agentv/update/progress.json" >"$RUN_DIR/progress.json" 2>&1 || true
check "S2.12 the update finishes ($(jq -r '"\(.state): \(.detail)"' "$RUN_DIR/progress.json" 2>/dev/null))" \
  jq -e '.state == "done" or .state == "restarting"' "$RUN_DIR/progress.json"
ssh_guest "cat /var/lib/agentv/update/update.log" >"$RUN_DIR/update.log" 2>&1 || true
jq -e '.state == "done" or .state == "restarting"' "$RUN_DIR/progress.json" >/dev/null 2>&1 || tail -n 30 "$RUN_DIR/update.log"
if [[ $(jq -r .state "$RUN_DIR/progress.json") == "restarting" ]]; then
  log "The update restarts the box"
  sleep 20
  wait_for_ssh 300 failure-update-tv-reboot-ssh-timeout || exit 1
  # Omarchy's flag outlives the restart, which isn't Omarchy's own.
  had_to() {
    [[ $(ssh_guest "uname -r") != "$kernel" ]] || ssh_guest "test -f ~/.local/state/omarchy/reboot-required"
  }
  check "the box restarted because it had to: a new kernel (was $kernel, now $(ssh_guest "uname -r")) or Omarchy's flag" had_to
else
  took=$(wait_running "$AGENTV_TEST_UPDATE_VERSION" 90) || took=""
  check "after an update from the TV, home is back in front, and AgenTV's daemon and screen daemon run agentv $AGENTV_TEST_UPDATE_VERSION${took:+ (after $took s)}" \
    test -n "$took"
  [[ -n $took ]] || { health; screen_status; } >"$RUN_DIR/running.json" 2>&1
  check "and the box didn't restart" test "$(ssh_guest "cat /proc/sys/kernel/random/boot_id")" = "$boot_id"
fi

after=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
check "S2.12 the box is on agentv $AGENTV_TEST_UPDATE_VERSION (was $before, now $after)" test "$after" = "$AGENTV_TEST_UPDATE_VERSION"
check "the owner's sudo goes back to asking for a password" ssh_sudo "! ls /etc/sudoers.d/99-omarchy-nopasswd-* 2>/dev/null | grep -q ."
# Omarchy's update ends by restarting its shell in the session that's
# running; the TV session stops it again.
check "after an update from the TV, Omarchy's shell isn't on the TV: no bar, no process (ADR-031)" no_omarchy_shell 30
screen_home() {
  ocr_screen >"$RUN_DIR/$1.txt" 2>/dev/null || true
  capture_console "$1"
  grep -qi "installed" "$RUN_DIR/$1.txt"
}
started=$SECONDS
until screen_home "success-update-tv-home" || (( SECONDS - started > 120 )); do sleep 5; done
check "S2.12 the TV is back on home after the update (OCR)" screen_home "success-update-tv-home"

# --- Go back (S2.14) ------------------------------------------------------------

ssh_guest "cat /var/lib/agentv/update/go-back.json" >"$RUN_DIR/go-back.json" 2>&1 || true
ssh_guest "cat /var/lib/agentv/update/after.json" >"$RUN_DIR/after.json" 2>&1 || true
# shellcheck disable=SC2016 # $before is jq's
check "S2.14 the update kept which snapshot Go back returns to" \
  jq -e --arg before "$before" '.snapshot > 0 and .from.agentv == $before' "$RUN_DIR/go-back.json"
check "S2.14 the check after the update passed ($(jq -c '[.checks[] | select(.ok | not) | .detail]' "$RUN_DIR/after.json" 2>/dev/null))" \
  jq -e '.ok and ([.checks[].name] | index("Clock"))' "$RUN_DIR/after.json"

# The update broke the app, as one might, and the check runs again.
ssh_sudo "echo 'export default {' >/var/lib/agentv/apps/local.clock/app.ts"
ssh_sudo "agentv-update-after" >"$RUN_DIR/check-again.txt" 2>&1 || true
check "S2.14 the check finds the app that won't load" grep -qx "not ok - Clock: Clock won't load" "$RUN_DIR/check-again.txt"

screen_off() {
  ocr_screen >"$RUN_DIR/$1.txt" 2>/dev/null || true
  capture_console "$1"
  grep -qi "go back to" "$RUN_DIR/$1.txt"
}
started=$SECONDS
until screen_off "success-go-back-off" || (( SECONDS - started > 60 )); do sleep 3; done
check "S2.14 the TV says something's off and offers Go back (OCR)" grep -Eqi "something.{0,2}s off" "$RUN_DIR/success-go-back-off.txt"
if ! grep -Eqi "something.{0,2}s off" "$RUN_DIR/success-go-back-off.txt"; then
  # What the TV showed, and what home was told about the update.
  cat "$RUN_DIR/success-go-back-off.txt"
  ssh_guest "curl -fsS http://127.0.0.1:3000/api/updates" | jq -c '{status: .status | {agentv, waiting}, goBack, after, seen}' 2>&1 || true
fi

# OK on the TV: Go back has the focus.
guest "agentv input key enter" >"$RUN_DIR/input.log" 2>&1 || true
check "S2.14 Go back starts from the TV" until_file '.state == "going-back"' /var/lib/agentv/update/progress.json 60
ocr_screen >"$RUN_DIR/success-go-back-going.txt" 2>/dev/null || true
capture_console "success-go-back-going"

log "Waiting for the box to restart into the snapshot from before the update"
started=$SECONDS
while ssh_guest true 2>/dev/null && (( SECONDS - started < 600 )); do sleep 3; done
wait_for_ssh 400 failure-go-back-ssh-timeout || exit 1
ssh_guest "journalctl -b -1 --no-pager -u agentv-go-back" >"$RUN_DIR/go-back.log" 2>&1 || true

back=$(ssh_guest "pacman -Q agentv" | cut -d' ' -f2)
check "S2.14 Go back returns the box to agentv $before (now $back), with no reinstall" test "$back" = "$before"
check "S2.14 the app the update broke is whole again" ssh_guest "grep -q 'local.clock' /var/lib/agentv/apps/local.clock/app.ts"
check "the box knows it went back" \
  ssh_guest "jq -e --arg before '$before' '.to.agentv == \$before' /var/lib/agentv/update/went-back.json"
started=$SECONDS
until screen_home "success-go-back-home" || (( SECONDS - started > 180 )); do sleep 5; done
check "S2.14 the TV is on home again after going back (OCR)" screen_home "success-go-back-home"

stop_vm
finish
