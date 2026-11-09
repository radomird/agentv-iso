#!/bin/bash
#
# T6.2: Omarchy's theme intros on the TV (ADR-064). With the dynamic
# backgrounds switched on:
#   - picking a theme whose background has an intro plays it on home, once,
#     from where Omarchy keeps it, and it ends on its still;
#   - with Omarchy's intros switched off (omarchy theme bg intro disable), a
#     theme with an intro shows its still, and home says why.
# The theme is set with Omarchy's own omarchy-theme-set, as the owner, which
# is what the TV runs when you pick one. Catppuccin's first background,
# 1-totoro, has an intro, and so does Nord's, 0-black-moon.
#
# A VM has no hardware video decoding, so the box would show the still.
# /etc/agentv/video-in-software lets this check's box play it anyway. On a
# real box, the box check's codecs decide (layer 4 checks that part).
# About four minutes, most of it the boot.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# until_json <url path> <jq filter> <seconds>: until the filter on what the
# daemon answers there is true.
until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000$1" 2>/dev/null | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 0.5
  done
  return 1
}

backgrounds() {
  ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/backgrounds" 2>/dev/null | jq -r "$1" 2>/dev/null || true
}

# The intro of the background Omarchy shows, as home's URL for it, or nothing.
# $c is jq's own.
# shellcheck disable=SC2016
current_intro() {
  backgrounds '(.theme.current) as $c | first(.theme.items[] | select(.id == $c)) | .intro // ""'
}

# apart <shot> <shot>: how far apart two screens are, 0 to 1. magick compare
# exits 1 when they differ, which is the point here.
apart() {
  { magick compare -metric RMSE "$RUN_DIR/$1.ppm" "$RUN_DIR/$2.ppm" null: 2>&1 || true; } | sed -nE 's/.*\(([0-9.e+-]+)\).*/\1/p'
}

shot() {
  screendump "$RUN_DIR/$1.ppm"
}

# The theme set as the owner, with Omarchy's own command.
theme_set() {
  guest "OMARCHY_PATH=/usr/share/omarchy PATH=/usr/share/omarchy/bin:\$PATH omarchy-theme-set $1" >>"$RUN_DIR/theme-set.log" 2>&1 || true
}

start_vm_from_base
wait_for_ssh 300 failure-T6.2-ssh-timeout || exit 1
wait_tv 300 >/dev/null || true
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "setup skipped, home is in front${took:+ (after $took s)}" test -n "$took"

# The switch on, as on an edge box, and video without hardware decoding.
ssh_sudo "echo edge >/etc/agentv/channel && touch /etc/agentv/video-in-software" >"$RUN_DIR/switch.log" 2>&1 || true
guest "agentv feature on dynamicbg" >>"$RUN_DIR/switch.log" 2>&1 || true
check "the daemon says the dynamic backgrounds are on" until_json /api/features '.dynamicbg == true' 10
check "and that this box plays videos without hardware decoding" until_json /api/backgrounds '.softwareVideo == true' 10

# Catppuccin: its first background has an intro.
theme_set catppuccin
check "T6.2 the TV has Catppuccin, with an intro due" \
  until_json /api/backgrounds '.theme.name == "catppuccin" and (.theme.introDue | type) == "string"' 60
due=$(backgrounds '.theme.introDue')
current=$(backgrounds '.theme.current')
intro=$(current_intro)
log "Catppuccin's background is $current, its intro at ${intro:-nowhere}, due as $due"
check "T6.2 the background Omarchy shows has its intro (${intro:-none})" grep -Eq '^/api/backgrounds/video/[0-9a-f]{16}$' <<<"$intro"

# The intro comes from where Omarchy keeps it, in parts, and isn't copied.
file=$(guest "ls ~/.local/state/omarchy/current/theme/backgrounds/intros/1-totoro.* 2>/dev/null | head -n 1")
size=$(guest "stat -c %s $file 2>/dev/null")
range=$(ssh_guest "curl -fsS -o /tmp/t6.2-part -w '%{http_code} %{size_download}' -H 'Range: bytes=0-999' http://127.0.0.1:3000$intro" 2>/dev/null || true)
check "T6.2 the intro streams from where Omarchy keeps it, in the parts asked for ($range, of $file, $size bytes)" test "$range" = "206 1000"
check "and those are its first bytes" test "$(guest "head -c 1000 $file | sha256sum | cut -c1-16")" = "$(ssh_guest "sha256sum /tmp/t6.2-part | cut -c1-16")"
check "and the daemon has no copy of it" test -z "$(ssh_sudo "find /var/lib/agentv/backgrounds -iname '*.mp4' -o -iname '*.webm'" 2>/dev/null)"

# Home plays it: it says so as it starts, and the screen moves.
check "T6.2 home plays the intro" \
  until_json /api/backgrounds ".theme.introShown == {\"due\": \"$due\", \"how\": \"played\", \"why\": null}" 30
shot intro-1
sleep 0.8
shot intro-2
moved=$(apart intro-1 intro-2)
capture_console "success-T6.2-intro"
check "T6.2 and it moves (two frames 0.8 s apart are ${moved:-?} apart, out of 1)" awk -v d="${moved:-0}" 'BEGIN { exit !(d > 0.01) }'

# It ends on its still, and stays there.
sleep 10
shot still-1
sleep 1.5
shot still-2
settled=$(apart still-1 still-2)
capture_console "success-T6.2-still"
check "T6.2 it ends on its still (two frames 1.5 s apart are ${settled:-?} apart)" awk -v d="${settled:-1}" 'BEGIN { exit !(d < 0.005) }'
check "and plays once: it isn't due again" until_json /api/backgrounds ".theme.introDue == \"$due\" and .theme.introShown.due == \"$due\"" 5

# Omarchy's intros switched off, then Nord, whose first background has an
# intro too: the still, and home says why.
guest "OMARCHY_PATH=/usr/share/omarchy PATH=/usr/share/omarchy/bin:\$PATH omarchy-theme-bg-intro disable" >>"$RUN_DIR/theme-set.log" 2>&1 || true
check "T6.2 home hears Omarchy's intros are off" until_json /api/backgrounds '.theme.intros == false' 30
theme_set nord
check "the TV has Nord, with an intro due" until_json /api/backgrounds ".theme.name == \"nord\" and (.theme.introDue | type) == \"string\" and .theme.introDue != \"$due\"" 60
off=$(backgrounds '.theme.introDue')
check "and its background has an intro" test -n "$(current_intro)"
check "T6.2 with the intros off, home shows the still instead, and says why" \
  until_json /api/backgrounds ".theme.introShown == {\"due\": \"$off\", \"how\": \"still\", \"why\": \"intros-off\"}" 30
shot off-1
sleep 1.5
shot off-2
still=$(apart off-1 off-2)
capture_console "success-T6.2-intros-off"
check "T6.2 and nothing moves (two frames 1.5 s apart are ${still:-?} apart)" awk -v d="${still:-1}" 'BEGIN { exit !(d < 0.005) }'

guest "journalctl --user -b --no-pager -u agentv-screen | grep -i 'themes:' | tail -n 20" >"$RUN_DIR/screen-themes.log" 2>&1 || true
stop_vm
finish
