#!/bin/bash
#
# Shared by AgenTV's image checks: when upstream's wait_for_ssh gives up on a
# VM that's still running, this says why before the check stops it.
# Upstream's wait throws ssh's own error away, so a box that booted to the TV
# while the host couldn't log in (the nightly run of 2026-10-31) left nothing
# to go on. Upstream's wait runs as it is; only on a timeout, this adds
# ssh's own words from one more try, and QEMU's table of the VM's user-mode
# network, which shows whether the port forward was there and where the
# connection stopped. Source it after upstream's base-test.sh; tv.sh and
# repos.sh do.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source test/agentv/image/ssh.sh from a check; don't run it" >&2
  exit 1
fi

if ! declare -F wait_for_ssh >/dev/null; then
  echo "ssh.sh: source upstream's base-test.sh first" >&2
  exit 1
fi

# Upstream's wait, kept under another name, once.
if ! declare -F upstream_wait_for_ssh >/dev/null; then
  eval "upstream_$(declare -f wait_for_ssh)"
fi

wait_for_ssh() {
  upstream_wait_for_ssh "$@" && return 0
  local status=$?
  if vm_running; then
    ssh_why
  fi
  return "$status"
}

# One more try at SSH, verbose, and QEMU's view of the VM's network, kept in
# the run's folder and printed, since the job's log is what's always there.
ssh_why() {
  ssh -v -i "$SSH_KEY" -p "$SSH_PORT" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    "$GUEST_USER@127.0.0.1" true >"$RUN_DIR/ssh-why.log" 2>&1 || true
  qmp '"human-monitor-command", "arguments": {"command-line": "info usernet"}' |
    jq -r 'select(.return | type == "string") | .return' >"$RUN_DIR/usernet.txt" 2>/dev/null || true
  log "SSH to 127.0.0.1:$SSH_PORT, one more try, verbose:"
  grep -v -E '^debug1: (Reading configuration|.*identity file|Local version|Remote protocol)' "$RUN_DIR/ssh-why.log" | tail -n 20 || true
  log "QEMU's user-mode network for this VM:"
  cat "$RUN_DIR/usernet.txt" 2>/dev/null || true
}
