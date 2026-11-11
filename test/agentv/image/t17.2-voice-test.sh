#!/bin/bash
#
# The TV's own voice on an installed box (T17.2, and the spoken half of
# S7.3), with a sound card that plays to nothing, as S2.19's check has.
#
# The voice is whatever the agentv-voice package ships, so this check goes
# by what the box has:
# - With a voice (a say program, or Piper in the package from before): a
#   Claude key has no voice of its own, so the very first "i didn't get
#   that" is made on the box and played by the TV session through PipeWire,
#   the daemon's log says which voice, and nothing logs the words.
# - With none (no agentv-voice installed): the same answer shows and isn't
#   said, the daemon says so once, Settings has nothing to offer, and
#   nothing fails. Then a stand-in for the old voice package goes on, as a
#   TV from before the update still has it, and the migration takes it off.
#
# With a voice it also says a few of the TV's real answers in each voice the
# package has, times them, and keeps the WAV files with the run's logs, so
# someone can listen before a voice ships.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

ROUTER_PORT=8777
DROPINS=/run/systemd/system

# start_vm_from_base, with a sound card.
qemu-img create -f qcow2 -b "$BASE_DISK" -F qcow2 "$RUN_DIR/run.qcow2" >/dev/null
cp "$BASE_OVMF" "$RUN_DIR/OVMF_VARS.4m.fd"
# shellcheck disable=SC2034 # start_vm reads it
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/serial.log" -audiodev none,id=snd0 -device intel-hda -device hda-output,audiodev=snd0
wait_for_ssh 300 failure-T17.2-voice-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-T17.2-voice-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 3

# Which voice the box has.
VOICE_DIR=/usr/lib/agentv-voice
if ssh_guest "test -x $VOICE_DIR/say"; then
  kind=say
elif ssh_guest "test -x $VOICE_DIR/piper/piper && test -f $VOICE_DIR/en_GB-cori-medium.onnx"; then
  kind=piper
else
  kind=none
fi
log "The box's own voice: $kind"
ssh_guest "pacman -Q agentv-voice; pacman -Qi agentv | sed -n '/^Depends On/,/^Optional Deps/p'" >"$RUN_DIR/voice-package.txt" 2>&1 || true

if [[ $kind == "none" ]]; then
  check "T17.2 with no voice, agentv-voice isn't installed and agentv doesn't ask for it" \
    ssh_guest "! pacman -Q agentv-voice && ! pacman -Qi agentv | sed -n '/^Depends On/,/^Optional Deps/p' | grep -qw agentv-voice && ! test -e $VOICE_DIR"
else
  check "agentv-voice is installed, as agentv needs it" ssh_guest "pacman -Q agentv-voice && pacman -Qi agentv | sed -n '/^Depends On/,/^Optional Deps/p' | grep -qw agentv-voice"
  ssh_guest "find $VOICE_DIR -maxdepth 2 -type f ! -path '*/espeak-ng-data/*' -printf '%p %u %m\\n' | sort" >"$RUN_DIR/voice-files.txt" 2>&1 || true
  check "the voice's files are root's, and none can be written by anyone else" bash -c "test -s '$RUN_DIR/voice-files.txt' && ! grep -v ' root [0-7]*[0145][0145]\$' '$RUN_DIR/voice-files.txt'"
fi

# A stand-in for Anthropic's API, which can't route anything, and a key
# for Claude with its terms accepted on a phone (Q104).
ssh_guest "cat >/tmp/router-standin.mjs" <<'STANDIN'
import { createServer } from "node:http";
const none = { intent: "none", query: null, kind: null, app: null, season: null, episode: null };
createServer(async (request, response) => {
  for await (const chunk of request) void chunk;
  response.writeHead(200, { "Content-Type": "application/json" });
  response.end(JSON.stringify({ type: "message", content: [{ type: "text", text: JSON.stringify(none) }], stop_reason: "end_turn", usage: { input_tokens: 1500, output_tokens: 40 } }));
}).listen(Number(process.argv[2]), "127.0.0.1");
STANDIN
ssh_guest "nohup node /tmp/router-standin.mjs $ROUTER_PORT >/tmp/router-standin.log 2>&1 </dev/null & disown" || true
ssh_guest "sudo mkdir -p $DROPINS/agentv-router.service.d && printf '[Service]\nEnvironment=AGENTV_ROUTER_UPSTREAM=http://127.0.0.1:$ROUTER_PORT\n' | sudo tee $DROPINS/agentv-router.service.d/standin.conf >/dev/null && sudo systemctl daemon-reload && sudo systemctl restart agentv-router.service"
KEY="sk-ant-api03-agentvvoicecheck$(printf '0%.0s' {1..30})"
put_key() {
  ssh_guest "curl -sS --max-time 20 -X PUT -H 'Content-Type: application/json' -d '{\"provider\":\"claude\",\"key\":\"$KEY\"}' http://127.0.0.1:3000/api/key" >"$RUN_DIR/$1.json" 2>&1 || true
}
put_key asked
phone_key=$(pair_phone 'image check')
ssh_guest "agentv-phone-call $phone_key POST /api/phone/terms '{\"provider\": \"claude\", \"path\": \"key\"}'" >/dev/null 2>&1 || true
put_key stored
check "a key for claude is kept for the router" jq -e '.set == true and .provider == "claude"' "$RUN_DIR/stored.json"
sleep 3

say_it() {
  ssh_guest "curl -sS --max-time 60 -H 'Content-Type: application/json' -d '{\"sentence\": \"the cat sat on the\"}' http://127.0.0.1:3000/api/say" >"$RUN_DIR/$1.json" 2>&1 || true
}
voice() {
  ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/voice" 2>/dev/null || echo '{}'
}

# --- The first answer ---------------------------------------------------------------

voice >"$RUN_DIR/voice-new.json"
before=$(voice | jq -r '.last.clip // 0')
say_it first
check "S7.3 a sentence that can't be routed is i didn't get that" jq -e '.said.outcome.say == "i didn'"'"'t get that"' "$RUN_DIR/first.json"

if [[ $kind == "none" ]]; then
  check "T17.2 the daemon says the TV has no voice of its own" jq -e '.own == "missing" and .by == null' "$RUN_DIR/voice-new.json"
  sleep 5
  voice >"$RUN_DIR/voice.json"
  cat "$RUN_DIR/voice.json"
  check "T17.2 with no voice the answer is only shown: no clip is made" jq -e '.last == null and .by == null' "$RUN_DIR/voice.json"
  say_it second
  check "T17.2 the next answer comes the same way" jq -e '.said.outcome.say == "i didn'"'"'t get that"' "$RUN_DIR/second.json"
else
  check "the daemon has the TV's own voice ready on a new box" jq -e '.own == "ready" and .by == "own"' "$RUN_DIR/voice-new.json"
  started=$SECONDS
  until voice | jq -e --argjson before "$before" '(.last.clip // 0) > $before and .last.played != null' >/dev/null || (( SECONDS - started > 90 )); do sleep 1; done
  voice >"$RUN_DIR/voice.json"
  cat "$RUN_DIR/voice.json"
  check "T17.2 the TV says i didn't get that aloud, in its own voice" jq -e '.by == "own" and .last.by == "own" and .last.played == true' "$RUN_DIR/voice.json"
  check "the voice made it in under 15 s (it took $(jq -r '.last.ms // "?"' "$RUN_DIR/voice.json") ms)" jq -e '.last.ms < 15000' "$RUN_DIR/voice.json"
fi

guest "agentv selftest S7.3" >"$RUN_DIR/selftest.log" 2>&1 || true
cat "$RUN_DIR/selftest.log"
if [[ $kind == "none" ]]; then
  check "agentv selftest S7.3 passes, and says the TV has no voice" grep -q '^pass S7.3 the TV has no voice of its own' "$RUN_DIR/selftest.log"
else
  check "agentv selftest S7.3 says the TV said it, in its own voice" grep -q '^pass S7.3 the TV said it aloud, with its own voice' "$RUN_DIR/selftest.log"
fi

ssh_sudo "journalctl -b --no-pager -u agentv-daemon -u agentv-router" >"$RUN_DIR/journal.log" 2>&1 || true
never_the_words() {
  ! grep -q -e "cat sat" -e "$KEY" "$RUN_DIR/journal.log"
}
check "the journal never has the words or the key" never_the_words
if [[ $kind == "none" ]]; then
  said_once() {
    (( $(grep -c "the tv has no voice of its own" "$RUN_DIR/journal.log") == 1 ))
  }
  check "T17.2 the journal says once that the TV has no voice of its own" said_once
  nothing_failed() {
    ! grep -Ei "voice.*(error|failed|didn't start|ENOENT)|unhandled|TypeError" "$RUN_DIR/journal.log"
  }
  check "T17.2 and nothing errors for want of a voice" nothing_failed
  ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/health" >"$RUN_DIR/health.json" 2>&1 || true
  check "the daemon is still up" jq -e '.ok == true' "$RUN_DIR/health.json"
else
  said_with_own() {
    grep -qE "the tv said its answer with its own voice, made in [0-9]+ ms$" "$RUN_DIR/journal.log"
  }
  check "the journal says the TV said it in its own voice" said_with_own
fi

# --- A few real answers, in each voice the package has -----------------------------------
#
# For a listen before a voice ships. Each line is said by the package's own
# program, as the daemon runs it, timed, and kept as a WAV file.

if [[ $kind != "none" ]]; then
  samples="$RUN_DIR/voice-samples"
  mkdir -p "$samples"
  ssh_guest "cat >/tmp/voice-lines.txt" <<'LINES'
I didn't get that.
Which one?
Big Buck Bunny, on Jellyfin.
Yes, a new episode of Cosmos Laundromat came out on Friday. The next one is on the fourteenth.
I couldn't find Sintel.
New this week: Tears of Steel, Spring, and Blade Runner twenty forty nine.
LINES
  ssh_guest "cat >/tmp/voice-samples.sh" <<'SAMPLES'
#!/bin/bash
# Says each line in each voice, and notes how long each took.
set -uo pipefail
dir=/usr/lib/agentv-voice
out=/tmp/voice-samples
rm -rf "$out"
mkdir -p "$out"
{
  echo "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
  echo "cpus: $(nproc)"
  echo "memory: $(awk '/MemTotal/ { printf "%.1f GB", $2 / 1048576 }' /proc/meminfo)"
  echo "package: $(pacman -Q agentv-voice 2>/dev/null)"
} >"$out/machine.txt"
if [[ -x $dir/say ]]; then
  mapfile -t voices < <("$dir/say" --voices)
else
  voices=(piper-cori)
fi
printf 'voice	line	ms	audio_ms	times_real_time
' >"$out/timings.txt"
for voice in "${voices[@]}"; do
  n=0
  while IFS= read -r line; do
    n=$(( n + 1 ))
    wav="$out/$voice-$n.wav"
    started=$(date +%s%N)
    if [[ -x $dir/say ]]; then
      AGENTV_VOICE=$voice AGENTV_VOICE_LOG="$out/$voice.log" "$dir/say" "$wav" <<<"$line"
    else
      LD_LIBRARY_PATH="$dir/piper" "$dir/piper/piper" --model "$dir/en_GB-cori-medium.onnx" --output_file "$wav" <<<"$line" >/dev/null 2>&1
    fi
    status=$?
    ms=$(( ($(date +%s%N) - started) / 1000000 ))
    audio=0
    if [[ $status == 0 && -s $wav ]]; then
      # A WAV file's length, from its header: bytes of sound over bytes a second.
      rate=$(od -An -t u4 -j 28 -N 4 "$wav" | tr -d ' ')
      audio=$(( ($(stat -c %s "$wav") - 44) * 1000 / (rate > 0 ? rate : 1) ))
    fi
    speed=$(awk -v a="$audio" -v m="$ms" 'BEGIN { if (m > 0) printf "%.2f", a / m; else print "0" }')
    printf '%s	%s	%s	%s	%s
' "$voice" "$n" "$ms" "$audio" "$speed" >>"$out/timings.txt"
  done </tmp/voice-lines.txt
done
SAMPLES
  ssh_guest "bash /tmp/voice-samples.sh" >"$RUN_DIR/voice-samples.log" 2>&1 || true
  # The files come back over SSH, one stream.
  ssh_guest "tar -C /tmp/voice-samples -cf - ." 2>/dev/null | tar -C "$samples" -xf - 2>/dev/null || true
  ssh_guest "cat /tmp/voice-lines.txt" >"$samples/lines.txt" 2>/dev/null || true
  cat "$samples/machine.txt" "$samples/timings.txt" 2>/dev/null || true
  # The logs here do hold the sample lines, which are the check's own words,
  # never something a person said. They're kept as .txt so the run keeps them.
  for file in "$samples"/*.log; do [[ -f $file ]] && mv "$file" "${file%.log}-log.txt"; done
  all_said() {
    local lines voices
    lines=$(wc -l <"$samples/lines.txt")
    voices=$(tail -n +2 "$samples/timings.txt" | cut -f1 | sort -u | wc -l)
    (( voices > 0 )) && (( $(find "$samples" -name '*.wav' -size +1k | wc -l) == lines * voices ))
  }
  check "T17.2 each of the TV's sample answers is said in each voice the package has" all_said
  none_dropped() {
    ! grep -l "OOV word skipped" "$samples"/*-log.txt 2>/dev/null
  }
  check "the voice skipped no word of the sample answers" none_dropped
fi

# --- A TV from before, which still has the old voice --------------------------------------
#
# On a box that ships no voice, the update leaves the old package behind as
# one nothing asks for, and a migration takes it off. Here a stand-in for
# that package goes on the box: the same name and the same files' places,
# with nothing of Piper in it. Then the migration runs, as an update runs it.

if [[ $kind == "none" ]]; then
  ssh_guest "bash -s" >"$RUN_DIR/old-voice.log" 2>&1 <<'OLD' || true
set -euo pipefail
work=$(mktemp -d)
mkdir -p "$work/usr/lib/agentv-voice/piper"
printf '#!/bin/bash\n# A stand-in: the old voice was here.\nexit 1\n' >"$work/usr/lib/agentv-voice/piper/piper"
chmod 755 "$work/usr/lib/agentv-voice/piper/piper"
: >"$work/usr/lib/agentv-voice/en_GB-cori-medium.onnx"
cat >"$work/.PKGINFO" <<INFO
pkgname = agentv-voice
pkgbase = agentv-voice
pkgver = 2023.11.14.2-1
pkgdesc = A stand-in for the voice package from before
url = https://github.com
builddate = 1700000000
packager = image check
size = 64
arch = x86_64
INFO
(cd "$work" && bsdtar -cf - .PKGINFO usr | zstd -q >"$work/agentv-voice-2023.11.14.2-1-x86_64.pkg.tar.zst")
sudo pacman -U --noconfirm "$work/agentv-voice-2023.11.14.2-1-x86_64.pkg.tar.zst"
OLD
  cat "$RUN_DIR/old-voice.log"
  check "a stand-in for the old voice package is on the box, as on a TV from before" ssh_guest "pacman -Q agentv-voice && test -x $VOICE_DIR/piper/piper"
  voice >"$RUN_DIR/voice-old.json"
  check "the daemon sees the old voice" jq -e '.own == "ready" and .by == "own"' "$RUN_DIR/voice-old.json"

  # The package has AgenTV's migrations in one folder.
  migration=$(guest "grep -l 'The TV ships with no voice of its own now' /usr/share/agentv/migrations/*.sh" 2>/dev/null | head -n 1 || true)
  check "the migration is on the box" test -n "$migration"
  guest "bash $migration" >"$RUN_DIR/migration.log" 2>&1 || true
  cat "$RUN_DIR/migration.log"
  check "T17.2 the migration takes the old voice off: no package, and nothing left in its folder" ssh_guest "! pacman -Q agentv-voice && ! test -e $VOICE_DIR"
  voice >"$RUN_DIR/voice-after.json"
  check "T17.2 the daemon has no voice of its own again" jq -e '.own == "missing" and .by == null' "$RUN_DIR/voice-after.json"
  say_it after
  check "T17.2 an answer still shows, and isn't said" jq -e '.said.outcome.say == "i didn'"'"'t get that"' "$RUN_DIR/after.json"
  sleep 3
  voice >"$RUN_DIR/voice-after-say.json"
  check "T17.2 no clip is made for it" jq -e '.last == null' "$RUN_DIR/voice-after-say.json"
  guest "bash $migration" >"$RUN_DIR/migration-again.log" 2>&1 || true
  check "the migration changes nothing the second time" ssh_guest "! pacman -Q agentv-voice"
  ssh_sudo "journalctl -b --no-pager -u agentv-daemon -u agentv-router" >"$RUN_DIR/journal-after.log" 2>&1 || true
  nothing_failed_after() {
    ! grep -Ei "voice.*(error|failed|didn't start|ENOENT)|unhandled|TypeError" "$RUN_DIR/journal-after.log"
  }
  check "T17.2 and nothing errors as the old voice goes" nothing_failed_after
  ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/health" >"$RUN_DIR/health-after.json" 2>&1 || true
  check "the daemon is still up" jq -e '.ok == true' "$RUN_DIR/health-after.json"
fi

ssh_guest "sudo rm -f '${DROPINS:?}/agentv-router.service.d/standin.conf' && sudo systemctl daemon-reload; pkill -f router-standin.mjs" || true
stop_vm
finish
