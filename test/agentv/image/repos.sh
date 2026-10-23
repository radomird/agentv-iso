#!/bin/bash
#
# Shared by the image checks that sync from the real package repositories,
# Omarchy's and AgenTV's edge release. Source it after upstream's
# base-test.sh.
#
# Edge is published again each time agentv-os or agentv-pkgs merges, and
# GitHub replaces a release asset by deleting it and uploading the new one.
# For a minute or two after, agentv.db's download can answer 404, and pacman
# then fails the whole sync. A box tries again with its next daily check; a
# check waits it out here instead of failing on its first try.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source test/agentv/image/repos.sh from a check; don't run it" >&2
  exit 1
fi

# sync_repos [<tries>]: pacman -Sy on the box until every repository
# answers, a minute apart. Each try's output goes to $RUN_DIR/sync.log.
sync_repos() {
  local tries=${1:-6} try
  for (( try = 1; try <= tries; try++ )); do
    echo "== try $try of $tries, $(date -u +%H:%M:%S)" >>"$RUN_DIR/sync.log"
    ssh_sudo "pacman -Sy" >>"$RUN_DIR/sync.log" 2>&1 && return 0
    (( try < tries )) && sleep 60
  done
  return 1
}
