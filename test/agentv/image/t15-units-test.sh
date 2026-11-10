#!/bin/bash
#
# How much of the box each of AgenTV's system services can reach (T15.2):
# systemd-analyze security on every agentv-* service, with a ceiling on its
# exposure score, so a unit can't quietly lose its sandbox in a later
# change. systemd scores a unit from 0 (shut in) to 10 (the whole system):
# lower is better. The security review of 2026-11-10 could only read the
# unit files, so this asks systemd on an installed box.
#
# Each unit is in one of three classes, with one ceiling per class:
# - sandboxed: what faces the network or runs code AgenTV didn't write: the
#   daemon, the voice router, the builder and its way out. These must stay
#   well shut in.
# - root, kept in: root's helpers that take a drop from the daemon. They
#   need root, and are kept to the paths they write.
# - root: one-shot helpers that are the system's own hands: first boot,
#   updates, going back, the hotspot. No ceiling worth the name; they're
#   listed so a new unit has to be put in a class on purpose.
# A unit that isn't in a class fails the check: say which it is.
#
# TIGHTEN AFTER THE FIRST RUN. The ceilings below are set from reading the
# unit files, not from a run. The table this prints (and units.txt in the
# run's folder) has every unit's real score: bring SANDBOXED_MAX and
# KEPT_IN_MAX down to just above the highest score in their class, or give
# a unit its own line in CEILING.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

SANDBOXED_MAX=7.0 # tighten: first guess, the daemon and the router should land near 4 to 6
KEPT_IN_MAX=9.2   # tighten: first guess, root with ProtectSystem= and a few paths
ROOT_MAX=10       # systemd's own top of the scale
# A unit that's meant to be sandboxed and scores this or more has lost its
# sandbox, whatever the ceilings above have been set to.
EXPOSED=9.0

SANDBOXED=(agentv-daemon agentv-router agentv-router-cli agentv-build-net agentv-npm-check
  agentv-builder@ agentv-builder-cli@ agentv-builder-sign-in@)
KEPT_IN=(agentv-build agentv-key agentv-setup-apps agentv-zone agentv-password@)
ROOT_HELPERS=(agentv-firstboot agentv-update-check agentv-update-tv agentv-update-after agentv-go-back
  agentv-go-back-cleanup agentv-hotspot agentv-hotspot-boot agentv-hotspot-drop agentv-share agentv-shares
  agentv-wake agentv-app-package@ agentv-boot-splash-release)
# A unit's own ceiling, when its class's is too loose or too tight for it.
declare -A CEILING=()

start_vm_from_base
wait_for_ssh 300 failure-t15-units-ssh-timeout || exit 1
passwordless_sudo
wait_tv 240 >/dev/null || true

# Every agentv-* service the package brings. A template is scored as an
# instance of it, since only an instance has settings to score.
ssh_guest "systemctl list-unit-files 'agentv-*' --type=service --no-legend --no-pager" >"$RUN_DIR/unit-files.txt" 2>&1 || true
mapfile -t units < <(awk '{ sub(/\.service$/, "", $1); print $1 }' "$RUN_DIR/unit-files.txt" | sort -u)
check "the box has AgenTV's services to score" test "${#units[@]}" -ge 10

: >"$RUN_DIR/units.txt"
: >"$RUN_DIR/security.txt"
for unit in "${units[@]}"; do
  instance="$unit.service"
  [[ $unit == *@ ]] && instance="${unit}t15.service"
  {
    echo "== $instance"
    ssh_sudo "systemd-analyze security --no-pager '$instance'" 2>&1 || true
  } >"$RUN_DIR/security-one.txt"
  cat "$RUN_DIR/security-one.txt" >>"$RUN_DIR/security.txt"
  # The last line: "→ Overall exposure level for <unit>: 4.9 OK".
  score=$(sed -n 's/.*Overall exposure level for [^:]*: \([0-9][0-9.]*\).*/\1/p' "$RUN_DIR/security-one.txt" | tail -n 1)
  echo "$unit ${score:-none}" >>"$RUN_DIR/units.txt"
done
rm -f "$RUN_DIR/security-one.txt"

in_list() {
  local name=$1 one
  shift
  for one in "$@"; do
    [[ $one == "$name" ]] && return 0
  done
  return 1
}
class_of() {
  if in_list "$1" "${SANDBOXED[@]}"; then
    echo sandboxed
  elif in_list "$1" "${KEPT_IN[@]}"; then
    echo kept-in
  elif in_list "$1" "${ROOT_HELPERS[@]}"; then
    echo root
  else
    echo none
  fi
}
ceiling_of() {
  if [[ -n ${CEILING[$1]:-} ]]; then
    echo "${CEILING[$1]}"
    return
  fi
  case "$(class_of "$1")" in
    sandboxed) echo "$SANDBOXED_MAX" ;;
    kept-in) echo "$KEPT_IN_MAX" ;;
    *) echo "$ROOT_MAX" ;;
  esac
}
# at_most <score> <ceiling>, and under <score> <limit>: awk compares the
# decimals.
at_most() {
  awk -v score="$1" -v max="$2" 'BEGIN { exit !(score ~ /^[0-9.]+$/ && score + 0 <= max + 0) }'
}
under() {
  awk -v score="$1" -v max="$2" 'BEGIN { exit !(score ~ /^[0-9.]+$/ && score + 0 < max + 0) }'
}

log "Exposure of each of AgenTV's services (0 is shut in, 10 is the whole system):"
printf '%-34s %-10s %-8s %s\n' unit class score ceiling
while read -r unit score; do
  printf '%-34s %-10s %-8s %s\n' "$unit" "$(class_of "$unit")" "$score" "$(ceiling_of "$unit")"
done <"$RUN_DIR/units.txt" | tee "$RUN_DIR/units-table.txt"

while read -r unit score; do
  class=$(class_of "$unit")
  check "T15.2 $unit is in a class, with a ceiling on what it can reach" test "$class" != none
  check "T15.2 systemd scores $unit ($score)" test "$score" != none
  check "T15.2 $unit ($class) scores $score, at most $(ceiling_of "$unit")" at_most "$score" "$(ceiling_of "$unit")"
  if [[ $class == "sandboxed" ]]; then
    check "T15.2 $unit hasn't lost its sandbox (under $EXPOSED)" under "$score" "$EXPOSED"
  fi
done <"$RUN_DIR/units.txt"

# And the other way round: every unit a class names is on the box, so a
# list doesn't keep a ceiling for a unit that's gone or renamed.
for unit in "${SANDBOXED[@]}" "${KEPT_IN[@]}" "${ROOT_HELPERS[@]}"; do
  check "T15.2 $unit, which has a class, is one of the box's services" in_list "$unit" "${units[@]}"
done

# The daemon runs with what its unit says: the settings that keep the
# kernel's knobs from it are the ones systemd applied.
ssh_guest "systemctl show agentv-daemon.service -p ProtectKernelTunables -p ProtectKernelModules -p ProtectKernelLogs -p ProtectControlGroups -p ProtectProc -p LockPersonality -p RestrictRealtime -p RestrictSUIDSGID -p RestrictAddressFamilies -p SystemCallArchitectures -p DynamicUser -p NoNewPrivileges" >"$RUN_DIR/daemon-show.txt" 2>&1 || true
cat "$RUN_DIR/daemon-show.txt"
for line in ProtectKernelTunables=yes ProtectKernelModules=yes ProtectKernelLogs=yes ProtectControlGroups=yes \
  ProtectProc=invisible LockPersonality=yes RestrictRealtime=yes RestrictSUIDSGID=yes SystemCallArchitectures=native \
  DynamicUser=yes NoNewPrivileges=yes; do
  check "the running daemon has $line" grep -qx "$line" "$RUN_DIR/daemon-show.txt"
done
check "the running daemon opens only local, IPv4, IPv6 and netlink sockets" \
  grep -Eqx "RestrictAddressFamilies=(AF_UNIX|AF_INET|AF_INET6|AF_NETLINK)( (AF_UNIX|AF_INET|AF_INET6|AF_NETLINK)){3}" "$RUN_DIR/daemon-show.txt"
# And it still does its work with them: the TV's pages answer, and so does
# the box check, which reads /proc, /sys and the GPU.
check "the daemon is running" ssh_guest "systemctl is-active agentv-daemon.service"
check "and answers" ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/health"
ssh_guest "curl -fsS --max-time 20 http://127.0.0.1:3000/api/box" >"$RUN_DIR/box.json" 2>&1 || true
check "the box check still answers from inside the sandbox" jq -e 'type == "object"' "$RUN_DIR/box.json"
# The daemon's log, kept with the run, and any line that reads like its own
# sandbox saying no. Printed, not judged: some of these words turn up for
# other reasons, so a person reads them after a change to the unit.
ssh_sudo "journalctl -b -u agentv-daemon.service --no-pager" >"$RUN_DIR/daemon.log" 2>&1 || true
log "Lines in the daemon's log that could be its sandbox refusing something (none is good):"
grep -Ei "EACCES|EPERM|permission denied|operation not permitted|address family not supported" "$RUN_DIR/daemon.log" | head -n 20 || true

stop_vm
finish
