#!/bin/bash
#
# The owner's account is never handed root by AgenTV (H1): on an installed
# box nothing of AgenTV's is in /etc/sudoers.d, first boot's splash left
# nothing there either, and sudo asks the owner for a password. A rule an
# earlier version left behind, as after a power cut halfway through an
# update, is gone after a restart. And polkit lets the owner's own account
# start the update units from the TV, and no other admin.
#
# What an update from the TV does to sudo while it runs is update-tv's check,
# which has an update to run.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-t15-sudoers-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true

# This is bin/agentv-sudo-lend. The Nightly's edge leg runs this on edge's
# last build, which may be from before it, so on a box without it this waits.
if ! ssh_guest "test -x /usr/bin/agentv-sudo-lend"; then
  log "This agentv still writes a sudo rule for an update ($(guest "agentv version" 2>/dev/null | head -n 1)); H1's check waits for the next one"
  stop_vm
  finish
  exit 0
fi

ssh_sudo "ls -la /etc/sudoers.d" >"$RUN_DIR/sudoers.txt" 2>&1 || true
check "H1 first boot left no sudo rule of AgenTV's in /etc/sudoers.d" \
  ssh_sudo "! ls /etc/sudoers.d/99-agentv-* 2>/dev/null | grep -q ."
check "H1 sudo asks the owner for a password" ssh_guest "! sudo -n true"
check "H1 nothing AgenTV installs writes a sudo rule" \
  ssh_sudo "! grep -l NOPASSWD /usr/bin/agentv-* /usr/share/agentv/install/tv/*.sh 2>/dev/null | grep -q ."
# The lent sudo is private as long as one process of the owner's can't trace
# another: the kernel's ptrace_scope is 1 or more, as Arch ships it.
check "H1 a process may be traced only by what started it (ptrace_scope $(ssh_guest "cat /proc/sys/kernel/yama/ptrace_scope" 2>/dev/null))" \
  ssh_guest "test \"\$(cat /proc/sys/kernel/yama/ptrace_scope)\" -ge 1"
# First boot set the splash through the sudo it lent that one call.
check "S0.4 first boot still set the splash, without the rule" \
  ssh_sudo "grep -q 'Completed: .*/branding.sh' /var/log/agentv-firstboot.log && cmp -s /usr/share/plymouth/themes/omarchy/logo.png /usr/share/agentv/branding/plymouth-logo.png"
check "nothing is left in /run from the lending" ssh_sudo "! ls -d /run/agentv-sudo.* 2>/dev/null | grep -q ."

# polkit, asked as root about a process of each account, with the unit and
# the verb as systemd passes them. 0 is yes with no question.
ssh_sudo "useradd -m -G wheel t15admin" >"$RUN_DIR/useradd.log" 2>&1 || true
ssh_guest "cat >/tmp/t15-polkit.sh" <<'SH'
# may <user> <unit> [<verb>]: polkit lets a process of theirs through unasked.
may() {
  local pid="" status runner
  runuser -u "$1" -- sleep 30 &
  runner=$!
  # The sleep runuser started, once it's there: on a busy box that can take
  # longer than a second, and the account may have a sleep of its own.
  for _ in $(seq 1 50); do
    pid=$(pgrep -P "$runner" -x sleep) && break
    sleep 0.2
  done
  pkcheck --action-id org.freedesktop.systemd1.manage-units --process "$pid" --detail unit "$2" --detail verb "${3:-start}" >/dev/null 2>&1
  status=$?
  kill "$pid" 2>/dev/null
  return "$status"
}
owner=$1
for unit in agentv-update-check.service agentv-update-tv.service agentv-go-back.service agentv-boot-splash-release.service agentv-wake.timer; do
  may "$owner" "$unit" && echo "owner yes $unit" || echo "owner no $unit"
  may t15admin "$unit" && echo "admin yes $unit" || echo "admin no $unit"
done
may "$owner" agentv-update-tv.service stop && echo "owner yes stop" || echo "owner no stop"
may "$owner" sshd.service && echo "owner yes sshd.service" || echo "owner no sshd.service"
SH
ssh_sudo "bash /tmp/t15-polkit.sh $GUEST_USER" >"$RUN_DIR/polkit.txt" 2>&1 || true
cat "$RUN_DIR/polkit.txt"
for unit in agentv-update-check.service agentv-update-tv.service agentv-go-back.service agentv-boot-splash-release.service agentv-wake.timer; do
  check "polkit lets the owner's own account start $unit from the TV" grep -qx "owner yes $unit" "$RUN_DIR/polkit.txt"
  check "H1 polkit asks another admin for a password to start $unit" grep -qx "admin no $unit" "$RUN_DIR/polkit.txt"
done
# shellcheck disable=SC2016 # the single quotes hold the command bash runs
check "and the owner may only start them: not stop one, and not another unit" \
  bash -c 'grep -qx "owner no stop" "$1" && grep -qx "owner no sshd.service" "$1"' _ "$RUN_DIR/polkit.txt"
# For real, with the unit that only looks: the other admin is refused, with
# nobody there to type a password.
check "H1 another admin can't start the update check without a password" \
  ssh_sudo "! runuser -u t15admin -- systemctl start --no-block --no-ask-password agentv-update-check.service"
check "H1 nor the update itself" \
  ssh_sudo "! runuser -u t15admin -- systemctl start --no-block --no-ask-password agentv-update-tv.service && ! systemctl is-active --quiet agentv-update-tv.service"

# A rule left behind by an earlier version: only a comment, so sudo stays as
# it is, under the name the old update gave its own. The restart takes it.
ssh_sudo "printf '%s\n' '# left behind by an update that lost power' >/etc/sudoers.d/99-agentv-update-$GUEST_USER && chmod 440 /etc/sudoers.d/99-agentv-update-$GUEST_USER && cp -p /etc/sudoers.d/99-agentv-update-$GUEST_USER /etc/sudoers.d/99-agentv-branding-$GUEST_USER"
check "a rule an earlier version left behind is there before the restart" \
  ssh_sudo "test -f /etc/sudoers.d/99-agentv-update-$GUEST_USER && test -f /etc/sudoers.d/99-agentv-branding-$GUEST_USER"
boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id")
ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
started=$SECONDS
while [[ $(ssh_guest "cat /proc/sys/kernel/random/boot_id" 2>/dev/null) == "$boot" ]] && (( SECONDS - started < 120 )); do sleep 3; done
wait_for_ssh 300 failure-t15-sudoers-reboot-ssh-timeout || exit 1
check "the box restarted" test "$(ssh_guest "cat /proc/sys/kernel/random/boot_id")" != "$boot"
check "H1 a sudo rule an earlier version left behind is gone after a restart" \
  ssh_sudo "! ls /etc/sudoers.d/99-agentv-* 2>/dev/null | grep -q ."

stop_vm
finish
