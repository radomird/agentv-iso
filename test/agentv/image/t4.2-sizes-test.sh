#!/bin/bash
#
# T4.2: the TV's sizes on a 4K TV (ADR-062), in a VM whose screen is
# 3840 x 2160. With the sizes switched on:
#   - each size gives its logical width: Hyprland runs the screen at
#     3840 x 2160 with the scale that makes the size's canvas, and home's
#     window is that wide;
#   - a stand-in service page, with body text at a desktop site's 16 px, is
#     that wide too, and its body text is at least 23 of the TV's pixels;
#   - a toast keeps its size in logical pixels, so on the TV it grows and
#     shrinks with the size;
#   - a size change applies within a second, and so does the switch;
#   - and a new TV session starts at the size picked, from the line the
#     screen daemon kept, without setting it again.
# About five minutes, most of it the boot and one switch to Omarchy's
# desktop and back.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# Upstream's start_vm_from_base, with virtio-gpu's screen at 3840 x 2160:
# the preferred mode in the EDID it gives the box, as a 4K TV's is.
qemu-img create -f qcow2 -b "$BASE_DISK" -F qcow2 "$RUN_DIR/run.qcow2" >/dev/null
if [[ $FIRMWARE == uefi ]]; then
  cp "$BASE_OVMF" "$RUN_DIR/OVMF_VARS.4m.fd"
  ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
fi
start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/serial.log" -global virtio-gpu-device.xres=3840 -global virtio-gpu-device.yres=2160

wait_for_ssh 300 failure-T4.2-ssh-timeout || exit 1
wait_tv 300 >/dev/null || { capture_console "failure-T4.2-no-tv"; check "the TV session came up" false; stop_vm; finish; }
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

# Hyprland's view of the screen: the first monitor that's on.
monitor() {
  guest_hyprctl "-j monitors" 2>/dev/null | jq -r "first(.[] | select(.disabled != true)) | $1" 2>/dev/null || true
}
guest_hyprctl "-j monitors" >"$RUN_DIR/monitors-before.json" 2>&1 || true
check "the VM's screen is 4K, as the TV's is (modes: $(monitor '.availableModes | join(" ")'))" \
  grep -q "3840x2160" <<<"$(monitor '.availableModes | join(" ")')"

# The sizes switched on, as on an edge box: switches turn on on edge only,
# and nothing updates during this check, so the box goes to edge by its
# channel file alone. The TV follows the switch at once, with no restart.
ssh_sudo "echo edge >/etc/agentv/channel" >"$RUN_DIR/switch.log" 2>&1 || true
guest "agentv feature on sizes" >>"$RUN_DIR/switch.log" 2>&1 || true
check "the daemon says the sizes are on" test "$(ssh_guest "curl -fsS http://127.0.0.1:3000/api/features" 2>/dev/null | jq -r '.sizes' 2>/dev/null)" = "true"
for _ in $(seq 1 30); do
  [[ $(monitor '"\(.width)x\(.height) \(.scale)"') == "3840x2160 2" ]] && break
  sleep 0.5
done
check "T4.2 with the sizes switched on, the TV moves at once to 3840 x 2160 at scale 2, standard's (it runs $(monitor '"\(.width)x\(.height) at \(.scale)"'))" \
  test "$(monitor '"\(.width)x\(.height) \(.scale)"')" = "3840x2160 2"

# The stand-in service page, served on the box itself.
ssh_guest "mkdir -p /tmp/agentv-sizes && cat >/tmp/agentv-sizes/index.html" <"$(dirname -- "${BASH_SOURCE[0]}")/pages/sizes.html"
ssh_guest "cd /tmp/agentv-sizes && (nohup python3 -m http.server 8767 --bind 127.0.0.1 >/dev/null 2>&1 &)"

# The window in front's width and height, in logical pixels.
front_size() {
  local address
  address=$(front '.front.address // ""')
  guest_hyprctl "-j clients" 2>/dev/null | jq -r --arg a "$address" 'first(.[] | select(.address == $a)) | "\(.size[0])x\(.size[1])"' 2>/dev/null || true
}

# wait_title <regex> <seconds>: the window in front's title.
wait_title() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(front '.front.title // ""') =~ $1 ]] && return 0
    sleep 0.3
  done
  return 1
}

# The toast's layer, in logical pixels: "width height".
toast_size() {
  guest_hyprctl "-j layers" 2>/dev/null | jq -r 'first(.. | objects | select(.namespace? == "agentv-toast")) | "\(.w) \(.h)"' 2>/dev/null || true
}

declare -A toast_tv
for entry in "larger 1600 900 2.4" "standard 1920 1080 2" "more 2400 1350 1.6"; do
  read -r size width height scale <<<"$entry"
  guest "agentv screen home" >>"$RUN_DIR/screen.log" 2>&1 || true
  sleep 2

  answer=$(ssh_guest "curl -fsS -X PUT -H 'Content-Type: application/json' -d '{\"size\":\"$size\"}' -o /tmp/agentv-size.json -w '%{time_total}' --max-time 10 http://127.0.0.1:3000/api/display && echo && cat /tmp/agentv-size.json" 2>/dev/null || true)
  took=$(head -n 1 <<<"$answer")
  printf '%s\n' "$answer" >"$RUN_DIR/put-$size.json"
  check "T4.2 $size: the screen daemon set it (answer: $(tail -n 1 <<<"$answer" | head -c 300))" \
    test "$(tail -n 1 <<<"$answer" | jq -r '.applied' 2>/dev/null)" = "true"
  check "T4.2 $size: the change applied within a second (took ${took:-?} s)" awk -v t="${took:-9}" 'BEGIN { exit !(t < 1) }'
  sleep 1
  guest_hyprctl "-j monitors" >"$RUN_DIR/monitors-$size.json" 2>&1 || true
  check "T4.2 $size: the TV runs at 3840 x 2160 at scale $scale (it runs $(monitor '"\(.width)x\(.height) at \(.scale)"'))" \
    awk -v got="$(monitor '"\(.width) \(.height) \(.scale)"')" -v want="$scale" 'BEGIN { split(got, g, " "); exit !(g[1] == 3840 && g[2] == 2160 && g[3] - want < 0.01 && want - g[3] < 0.01) }'
  check "T4.2 $size: its logical width is $width (3840 / $(monitor .scale))" \
    awk -v s="$(monitor .scale)" -v w="$width" 'BEGIN { exit !(s > 0 && int(3840 / s + 0.5) == w) }'
  check "T4.2 $size: home's window is ${width} x ${height} (it's $(front_size))" test "$(front_size)" = "${width}x${height}"

  # The service page: as wide as the canvas, with its body text at least
  # 23 of the TV's pixels.
  guest "agentv screen open http://127.0.0.1:8767/" >>"$RUN_DIR/screen.log" 2>&1 || true
  wait_title "^sizes $width " 30 || true
  title=$(front '.front.title // ""')
  printf '%s: %s\n' "$size" "$title" >>"$RUN_DIR/page-titles.txt"
  check "T4.2 $size: a service page is $width wide too (its title: $title)" grep -q "^sizes $width " <<<"$title"
  check "T4.2 $size: and its 16 px body text is at least 23 px on the TV (it's $(awk '{ print $3 }' <<<"$title") px)" \
    awk -v px="$(awk '{ print $3 }' <<<"$title")" 'BEGIN { exit !(px >= 23) }'

  # A toast over the page: the same size in logical pixels, so the TV's
  # scale makes it bigger or smaller.
  guest "agentv screen toast 'a toast at $size'" >>"$RUN_DIR/screen.log" 2>&1 || true
  sleep 1
  read -r tw th <<<"$(toast_size)"
  capture_console "success-T4.2-$size"
  toast_tv[$size]=$(awk -v h="${th:-0}" -v s="$scale" 'BEGIN { printf "%d", h * s + 0.5 }')
  printf '%s: logical %s x %s, on the TV %s px tall\n' "$size" "${tw:-?}" "${th:-?}" "${toast_tv[$size]}" >>"$RUN_DIR/toasts.txt"
  check "T4.2 $size: a toast shows over the page (${tw:-no} x ${th:-toast} logical)" test -n "$th"
done
check "T4.2 a toast scales with the size: on the TV it's ${toast_tv[larger]} px tall at larger, ${toast_tv[standard]} at standard and ${toast_tv[more]} at more" \
  awk -v a="${toast_tv[larger]}" -v b="${toast_tv[standard]}" -v c="${toast_tv[more]}" 'BEGIN { exit !(a > b && b > c && c > 0) }'

# A new TV session, by way of Omarchy's desktop: it starts at the size
# picked, from the line the screen daemon kept, so the daemon finds the TV
# already there and sets nothing.
ssh_guest "curl -fsS -X PUT -H 'Content-Type: application/json' -d '{\"size\":\"larger\"}' --max-time 10 http://127.0.0.1:3000/api/display" >"$RUN_DIR/put-again.json" 2>&1 || true
kept=$(guest "cat \"\${XDG_STATE_HOME:-\$HOME/.local/state}/agentv/display\"" 2>/dev/null | tr -d '\r' || true)
check "T4.2 the screen daemon keeps the line the next session starts at (it's: $kept)" grep -Eq '^[A-Za-z0-9._-]+ 3840x2160@[0-9.]+ 2\.4$' <<<"$kept"
guest "agentv desktop" >>"$RUN_DIR/switch.log" 2>&1 || true
wait_desktop 60 >/dev/null || true
since=$(ssh_guest "date +%s" 2>/dev/null | tr -d '\r' || true)
guest "agentv tv" >>"$RUN_DIR/switch.log" 2>&1 || true
wait_home 120 >/dev/null || true
sleep 3
guest_hyprctl "-j monitors" >"$RUN_DIR/monitors-again.json" 2>&1 || true
guest "journalctl --user -u agentv-screen --since @${since:-0} --no-pager" >"$RUN_DIR/agentv-screen-again.log" 2>&1 || true
check "T4.2 the new TV session runs at larger's scale 2.4 (scale $(monitor .scale))" \
  awk -v s="$(monitor .scale)" 'BEGIN { exit !(s - 2.4 < 0.01 && 2.4 - s < 0.01) }'
check "T4.2 and it started there: the screen daemon had nothing to set" \
  bash -c "! grep -q 'display: .* at 3840x2160' '$RUN_DIR/agentv-screen-again.log'"
capture_console "success-T4.2-new-session"

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/agentv-screen.log" 2>&1 || true
ssh_sudo "journalctl -b --no-pager -u agentv-daemon" >"$RUN_DIR/agentv-daemon.log" 2>&1 || true
stop_vm
finish
