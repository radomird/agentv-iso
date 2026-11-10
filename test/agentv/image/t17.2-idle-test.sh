#!/bin/bash
#
# One idle screen (T17.2). The terminal screensaver is gone, so when the TV
# is idle it shows home's own ambient screen, with nothing else in front of
# it: no terminal, no effect. This box starts as one that had picked the
# terminal screensaver before the update. The migration makes it forget the
# pick and keep the rest of its settings. Then the TV is left alone with a
# paused app in front, with the wait set to 45 s by agentv screen idle-after.
# One key brings the app back.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

wait_front() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(front '.front.role // ""') == "$1" ]] && return 0
    sleep 0.5
  done
  return 1
}

# until_status <jq filter> <seconds>: until the filter is true.
until_status() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    jq -e "$1" <<<"$(screen_status)" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

settings() {
  ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/home" 2>/dev/null | jq -c '.settings'
}

start_vm_from_base
wait_for_ssh 300 failure-T17.2-idle-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "setup skipped, home is in front${took:+ (after $took s)}" test -n "$took"

check "T17.2 there's no terminal screensaver on the box" guest "! type -P agentv-screensaver && ! test -e /usr/share/agentv/bin/agentv-screensaver"

# A box from before: the terminal screensaver picked, and a wait of 30
# minutes, in the daemon's own settings.
file=/var/lib/private/agentv/daemon/settings.json
ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"idleMinutes\": 30}' http://127.0.0.1:3000/api/settings" >"$RUN_DIR/settings-set.json" 2>&1 || true
ssh_guest "sudo jq '. + {ambient: \"terminal\"}' $file | sudo tee $file.test >/dev/null && sudo chown --reference=$file $file.test && sudo mv $file.test $file" >"$RUN_DIR/settings-old.log" 2>&1 || true
check "the box's settings say terminal, as before the update" ssh_sudo "jq -e '.ambient == \"terminal\" and .idleMinutes == 30' $file"
check "T17.2 home never hears of the pick" test "$(settings | jq -r 'has("ambient")')" = "false"

# The package has AgenTV's migrations in one folder.
migration=$(guest "grep -l 'The terminal screensaver is gone' /usr/share/agentv/migrations/*.sh" 2>/dev/null | head -n 1 || true)
check "the migration is on the box" test -n "$migration"
guest "bash $migration" >"$RUN_DIR/migration.log" 2>&1 || true
check "T17.2 the migration takes the pick out of the box's settings" ssh_sudo "jq -e 'has(\"ambient\") | not' $file"
check "T17.2 and keeps the rest: the wait is still 30 minutes" ssh_sudo "jq -e '.idleMinutes == 30' $file"
check "the daemon still reads its settings" test "$(settings | jq -r '.idleMinutes')" = "30"

# An app in front, paused, and the TV left alone.
ssh_guest "mkdir -p /tmp/agentv-page && cat >/tmp/agentv-page/index.html" <"$(dirname -- "${BASH_SOURCE[0]}")/pages/media.html"
ssh_guest "cd /tmp/agentv-page && (nohup python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &)"
guest "agentv screen open http://127.0.0.1:8765/" >>"$RUN_DIR/screen.log" 2>&1 || true
check "the stand-in app opens in front" wait_front web 60
guest "agentv screen idle-after 45" >>"$RUN_DIR/screen.log" 2>&1 || true

log "Leaving the TV alone, with the app paused"
check "T17.2 idle shows the ambient screen" until_status '.ambient' 150
sleep 12
check "T17.2 home is what's in front, on its ambient screen" test "$(front '[.ambient, .front.role] | map(tostring) | join(" ")')" = "true home"
check "T17.2 no terminal and no effect runs for it" guest "! pgrep -x ttfx && ! pgrep -f org.agentv.screensaver"
# Its date, in the corner over the background's picture.
check "T17.2 the ambient screen is on the TV (OCR)" ocr_finds success-T17.2-idle '(mon|tues|wednes|thurs|fri|satur|sun)day' 15
capture_console "success-T17.2-idle"
guest_hyprctl clients -j >"$RUN_DIR/clients.json" 2>&1 || true
check "T17.2 the TV session has no terminal window" jq -e '[.[] | select(.class | test("screensaver|foot"; "i"))] | length == 0' "$RUN_DIR/clients.json"

# One key on the remote.
guest "agentv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
check "T17.2 one key brings back the app" wait_front web 15
check "and the ambient screen is over" test "$(front '.ambient')" = "false"

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen-journal.log" 2>&1 || true
stop_vm
finish
