#!/bin/bash
#
# Shared by the checks that boot the USB stick itself and install from
# AgenTV's first screen on it (T1.1, T1.2). Source it after upstream's
# base-test.sh and tv.sh.
#
# Nobody types into the installed box, so these checks need a way in. A
# drive with cloud-init's two files on it, and no installer answers, gives
# the harness root on the live system (the installer doesn't take it for an
# autoinstall). From there the harness's key goes in /root/authorized_keys,
# which Omarchy's install gives the new account, as an autoinstall's does.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source test/agentv/image/first-screen.sh from a check; don't run it" >&2
  exit 1
fi

# What only Omarchy's questions say, and never AgenTV's first screen, its
# install's tips or TV setup. "password" isn't one: a tip says "No password
# to type". OCR reads this console font's w as u at times, so no word here
# depends on a w.
OMARCHY_QUESTIONS='keyboard layout|username|hostname|timezone|select install disk|confirm over|look right|reboot no'

# A 4 MB drive with cloud-init's files and nothing else. Prints its path.
live_cidata() {
  local dir="$RUN_DIR/cidata-live" image="$RUN_DIR/cidata-live.img"
  rm -rf "$dir"
  mkdir -p "$dir"
  cidata_cloud_init "$dir"
  rm -f "$image"
  truncate -s 4M "$image"
  mkfs.vfat -n CIDATA "$image" >/dev/null
  mcopy -i "$image" "$dir"/* ::/
  printf '%s\n' "$image"
}

# boot_stick <name> [qemu args]: a blank disk, the ISO, and the drive above.
# The firmware starts the ISO, since the disk has nothing on it, and the
# installed disk after the install's restart. The VM's serial log is
# $STICK_SERIAL.
boot_stick() {
  local name=$1 cidata
  shift
  cidata=$(live_cidata)
  qemu-img create -f qcow2 "$RUN_DIR/$name.qcow2" "${DISK_GB}G" >/dev/null
  cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.$name.fd"
  # shellcheck disable=SC2034 # start_vm reads it
  ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.$name.fd"
  STICK_SERIAL="$RUN_DIR/$name-serial.log"
  start_vm "$RUN_DIR/$name.qcow2" "$STICK_SERIAL" \
    -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
    -device ide-cd,drive=cdrom0,bootindex=2 \
    -drive "file=$cidata,format=raw,if=none,id=cidata" \
    -device usb-storage,drive=cidata \
    "${LIVE_CIDATA_SMBIOS[@]}" "$@"
}

# The harness's key, for the account the install makes.
give_key() {
  ssh_live_root "umask 077 && cat >/root/authorized_keys" <"$SSH_KEY.pub"
}

# Keeps what the live system says about the install and the phone's side,
# for a run that failed.
keep_install_logs() {
  ssh_live_root "cat /run/agentv-first-screen/phone.log /run/agentv-first-screen/wpa_supplicant.log /run/agentv-first-screen/dnsmasq.log" >"$RUN_DIR/phone-side.log" 2>&1 || true
  ssh_live_root "cat /run/agentv-first-screen/phone.json; iw dev; ip -br addr; systemctl is-active iwd" >"$RUN_DIR/radios.txt" 2>&1 || true
  ssh_live_root "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
  ssh_live_root "cat /run/omarchy-install/state.json" >"$RUN_DIR/state.json" 2>/dev/null || true
  ssh_live_root "journalctl -b --no-pager | tail -n 300" >"$RUN_DIR/live-journal.txt" 2>/dev/null || true
}

# wait_for_box <name>: until the installed box answers SSH as $GUEST_USER,
# reading the screen every 10 s. Until the box starts from its own disk,
# any of Omarchy's questions on it go in $QUESTIONS_SEEN, with what OCR read.
# Fails when the install stops or takes too long.
wait_for_box() {
  local name=$1 waited=0 text installed=0
  QUESTIONS_SEEN=""
  while ! ssh_guest true 2>/dev/null; do
    if ! vm_running; then
      echo "The VM stopped while it installed" >&2
      return 1
    fi
    if (( waited >= INSTALL_TIMEOUT )); then
      capture_console "failure-$name-timeout"
      keep_install_logs
      echo "Timed out after ${waited}s waiting for the installed box" >&2
      return 1
    fi
    if (( ! installed )) && installed_system_started "$STICK_SERIAL"; then
      installed=1
      log "The box restarted by itself after about ${waited}s, from its own disk"
      capture_console "success-$name-restarted"
    fi
    if (( ! installed )); then
      text=$(ocr_screen)
      if grep -qiE "$OMARCHY_QUESTIONS" <<<"$text"; then
        QUESTIONS_SEEN+="$text"$'\n'
        capture_console "failure-$name-question-${waited}s"
      fi
      if grep -qi "installation stopped" <<<"$text"; then
        capture_console "failure-$name-stopped"
        keep_install_logs
        echo "The install stopped" >&2
        return 1
      fi
      if (( waited % 120 == 0 )); then
        capture_console "success-$name-installing-$(printf '%04d' "$waited")s"
      fi
    fi
    sleep 10
    (( waited += 10 ))
  done
  capture_console "success-$name-first-boot"
}

# The TV shows setup's first screen, as the daemon's /health says.
tv_setup_on_screen() {
  local status
  for _ in $(seq 1 60); do
    status=$(health)
    [[ $(jq -r '.screen + " " + (.welcome_shown | tostring)' <<<"$status" 2>/dev/null) == "welcome true" ]] && return 0
    sleep 5
  done
  printf '%s\n' "$status" >"$RUN_DIR/health.json"
  return 1
}
