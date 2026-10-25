#!/bin/bash
#
# The ledger on an installed box (S3.3): agentv selftest S3.3 installs a
# stand-in player app, opens it the way its tile would, and times its row in
# the ledger, which the screen daemon fills from the app's own page in the
# services' Chromium. Then the stand-in and its rows are gone again, and the
# ledger is the daemon's own database. A second viewer's row comes with
# stage 4's profiles; layer 2 checks it now.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-ledger-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-ledger-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

guest "agentv selftest S3.3" >"$RUN_DIR/selftest.txt" 2>&1 || true
cat "$RUN_DIR/selftest.txt"
check "S3.3 a ledger row appears within 10 s of an app opening" grep -q "^pass S3.3 a ledger row appeared" "$RUN_DIR/selftest.txt"
check "the row is the stand-in's episode, for the box's own person" \
  grep -qE "^pass S3.3 .*: $GUEST_USER, agentv selftest S1 E1 at [0-9]+ s$" "$RUN_DIR/selftest.txt"
check "the stand-in is gone after" ssh_guest "test ! -e /var/lib/agentv/apps/local.selftest-player"
check "and so are its rows" test "$(ssh_guest "curl -fsS --max-time 3 'http://127.0.0.1:3000/api/ledger?app=local.selftest-player'" | jq '.rows | length')" = "0"
check "the ledger is the daemon's own database" ssh_sudo "test -s /var/lib/private/agentv/daemon/ledger.db"

guest "journalctl --user -b --no-pager -u agentv-screen" >"$RUN_DIR/screen.log" 2>&1 || true
ssh_guest "journalctl -b --no-pager -u agentv-daemon" >"$RUN_DIR/daemon.log" 2>&1 || true
stop_vm
finish
