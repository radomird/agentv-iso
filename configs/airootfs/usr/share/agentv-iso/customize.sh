#!/bin/bash

# Adds AgenTV to the live ISO without editing a file of omarchy-iso's
# (ADR-025): AgenTV's packages go into the offline mirror the installer reads,
# and onto the installer's package list beside Omarchy's own package, so the
# installed box gets them in the same pacstrap. Runs once, in the live
# system's chroot, from /root/customize_airootfs.sh. bin/agentv-iso-packages
# put the packages here before the build, with their signatures checked.

set -euo pipefail

here=/usr/share/agentv-iso
mirror=/var/cache/omarchy/mirror/offline
lists=/usr/share/omarchy-iso

shopt -s nullglob
packages=("$here"/packages/*.pkg.tar.zst)
shopt -u nullglob
if (( ${#packages[@]} == 0 )); then
  echo "agentv-iso: no AgenTV packages in $here/packages; run bin/agentv-iso-packages first" >&2
  exit 1
fi

added=()
for package in "${packages[@]}"; do
  cp "$package" "$mirror/"
  added+=("$mirror/${package##*/}")
done
repo-add --quiet "$mirror/offline.db.tar.gz" "${added[@]}"

# The installer installs every line of the list that fits this machine.
for list in "$lists"/omarchy-base*.packages; do
  for name in agentv-keyring agentv; do
    grep -qxF "$name" "$list" || printf '%s\n' "$name" >>"$list"
  done
done

# Everything AgenTV's packages need has to be in the mirror already, or the
# install would stop halfway through on someone's box. Stop the build instead.
dbpath=$(mktemp -d)
pacman --dbpath "$dbpath" -Sy >/dev/null
if ! pacman --dbpath "$dbpath" -S --print --print-format '%n %v' agentv-keyring agentv; then
  echo "agentv-iso: AgenTV's packages need something the offline mirror doesn't have" >&2
  exit 1
fi
rm -rf "$dbpath"

# The installer's logo (ADR-021): the greeter, the configurator and the
# install dashboard read /usr/share/omarchy/logo.txt. This changes the live
# ISO only; on the installed box Omarchy's own package owns that file.
# logo.txt comes from agentv-os's branding/build.py and keeps its 81 columns,
# which the dashboard takes its width from.
install -D -m 644 "$here/logo.txt" /usr/share/omarchy/logo.txt

# The greeter's tagline (ADR-027). Under AgenTV's logo, Omarchy's own line,
# "Beautiful, Fun & Agentic Linux by DHH", would read as if DHH made AgenTV.
# It becomes AgenTV's public tagline; the logo still says powered by omarchy.
# Stop if upstream has moved the line, rather than ship it.
export AGENTV_TAGLINE="The world's first open-source agentic TV OS"
if ! grep -q '^  tagline="Beautiful, Fun & Agentic Linux by DHH"$' /root/configurator; then
  echo "agentv-iso: the greeter's tagline in /root/configurator has moved upstream" >&2
  exit 1
fi
perl -pi -e 's/^  tagline="Beautiful, Fun & Agentic Linux by DHH"$/  tagline="$ENV{AGENTV_TAGLINE}"/' /root/configurator

echo "agentv-iso: added ${#added[@]} AgenTV packages to the offline mirror and the install, and AgenTV's logo and tagline"
