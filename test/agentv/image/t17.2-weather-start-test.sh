#!/bin/bash
#
# The weather after a start (T17.2). Home draws within seconds of the box
# starting, often before it's online, so Weather's first ask for its
# forecast can fail. The tile used to stay empty until home was left and
# come back to. Now it waits, asks again by itself, and shows the forecast
# once MET Norway can be reached, with nothing pressed.
#
# The box can't be taken offline here without losing SSH, so MET Norway's
# name points at the box itself as it restarts, where nothing answers. Then
# the name is put back, and only the screen is read: asking the daemon for
# the tile from here would fetch the forecast for it.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-weather-start-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-weather-start-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

# screen_says <name> <text> [<seconds>]: until OCR finds <text> on the TV,
# keeping the last screenshot as <name>.
screen_says() {
  local started=$SECONDS

  while (( SECONDS - started < ${3:-30} )); do
    ocr_screen >"$RUN_DIR/$1.txt" 2>/dev/null || true
    if grep -qi "$2" "$RUN_DIR/$1.txt"; then
      capture_console "$1"
      return 0
    fi
    sleep 2
  done
  capture_console "$1"
  return 1
}

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

# Oslo's weather, large, where OCR reads it best.
ssh_sudo "timedatectl set-timezone Europe/Oslo" >"$RUN_DIR/timezone.log" 2>&1 || true
ssh_guest "curl -fsS -X PUT -H 'Content-Type: application/json' -d '{\"layout\":[{\"id\":\"agentv.weather\",\"x\":0,\"y\":0,\"size\":\"l\"},{\"id\":\"agentv.clock\",\"x\":2,\"y\":0,\"size\":\"m\"}]}' http://127.0.0.1:3000/api/layout" \
  >"$RUN_DIR/layout.json" 2>&1 || true

# MET Norway can't be reached as the box starts.
ssh_sudo "sed -i '\$a 127.0.0.1 api.met.no' /etc/hosts" >"$RUN_DIR/hosts.log" 2>&1 || true
check "MET Norway's name points at the box itself" ssh_guest "grep -q '^127.0.0.1 api.met.no$' /etc/hosts"
log "Restarting the box with no way to the forecast"
ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
sleep 15
wait_for_ssh 300 failure-weather-start-reboot-ssh-timeout || exit 1
wait_home 240 >/dev/null || check "the TV came back to home" false
sleep 8

waiting=$(ssh_guest "curl -fsS --max-time 10 http://127.0.0.1:3000/api/tile/agentv.weather/l" 2>/dev/null || true)
printf '%s\n' "$waiting" >"$RUN_DIR/weather-waiting.json"
check "after a start with no way to the forecast, the daemon says the tile is waiting" \
  jq -e '.tile == null and .waiting == true' "$RUN_DIR/weather-waiting.json"
ocr_screen >"$RUN_DIR/weather-waiting.txt" 2>/dev/null || true
capture_console "success-weather-start-waiting"
check "the TV shows no forecast yet (OCR)" bash -c "! grep -qi '7 days' '$RUN_DIR/weather-waiting.txt'"

# The box comes online. Nothing is pressed and nothing asks the daemon:
# home asks again by itself.
ssh_sudo "sed -i '/ api.met.no\$/d' /etc/hosts" >>"$RUN_DIR/hosts.log" 2>&1 || true
check "MET Norway's name is its own again" ssh_guest "! grep -q 'api.met.no' /etc/hosts"
check "T17.2 home shows the weather without being left (OCR)" screen_says "success-weather-start" "7 days" 180
check "the forecast is Oslo's (OCR)" grep -qi "oslo" "$RUN_DIR/success-weather-start.txt"
check "home is still what's in front" test "$(front '.front.role // ""')" = "home"

ssh_guest "journalctl -b --no-pager -u agentv-daemon" >"$RUN_DIR/daemon.log" 2>&1 || true
stop_vm
finish
