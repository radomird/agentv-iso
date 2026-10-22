#!/bin/bash
#
# S0.7, on a real box: once the nightly run has published tonight's signed
# tested.json, the box fetches it from the address its own package names,
# checks the signature with AgenTV's key, and takes an update of versions it
# lists, but holds back one it doesn't. Runs when $AGENTV_TEST_TESTED_LIVE is
# 1, after the publish.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"

if [[ ${AGENTV_TEST_TESTED_LIVE:-} != 1 ]]; then
  log "No tested.json published by this run; skipping"
  exit 0
fi
base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-S0.7-ssh-timeout || exit 1

# A version of omarchy that tested.json doesn't list.
installed=$(ssh_guest "pacman -Q omarchy" | cut -d' ' -f2)
ssh_guest "printf 'omarchy %s -> 999.0.0-1\n' '$installed' >/tmp/untested; : >/tmp/nothing"

check "S0.7 the box takes what tonight's signed tested.json lists" \
  ssh_guest "agentv-tested --pending /tmp/nothing"
check "S0.7 the box holds back a version tested.json doesn't list" \
  ssh_guest "! agentv-tested --pending /tmp/untested"

ssh_guest "agentv-tested --pending /tmp/untested" >"$RUN_DIR/held.txt" 2>&1 || true
stop_vm
finish
