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

# The logo in AgenTV's colours (ADR-028). The greeter, every step's header
# and the install dashboard's finish screen draw logo.txt all in Omarchy's
# green; they draw it with agentv-logo instead. The greeter's green colour
# shift animation goes, and the finish screen's laser etch settles on AgenTV's
# blue before the two-colour logo is drawn over it. Each change stops the
# build if upstream has moved the line it replaces.
install -D -m 644 "$here/logo.ansi" /usr/local/share/agentv/logo.ansi
install -D -m 755 "$here/agentv-logo" /usr/local/bin/agentv-logo

# patch <file> <description> <perl substitution, -0 so it can span lines>
patch() {
  local file="$1" what="$2" expression="$3" before
  before=$(mktemp)
  cp "$file" "$before"
  perl -0pi -e "$expression" "$file"
  if cmp -s "$before" "$file"; then
    rm -f "$before"
    echo "agentv-iso: $what in $file has moved upstream" >&2
    exit 1
  fi
  rm -f "$before"
}

configurator=/root/configurator
dashboard=/usr/local/bin/omarchy-install-dashboard

# shellcheck disable=SC2016 # the single quotes hold perl
patch "$configurator" "the step header's logo" \
  's/^  gum style --foreground 2 --padding "1 0 0 \$PADDING_LEFT" "\$\(<"\$LOGO_PATH"\)"$/  agentv-logo --top 1 --pad "\$PADDING_LEFT"/m'
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$configurator" "the greeter's logo" \
  's/^  gum style --foreground 2 --padding "0 0 0 \$PADDING_LEFT" "\$\(<"\$LOGO_PATH"\)"$/  agentv-logo --pad "\$PADDING_LEFT"/m'
# The greeter waits for Return and then stops $anim, so something has to run.
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$configurator" "the greeter's animation" \
  's/^  ttfx -i "\$LOGO_PATH" \\\n.*?^    <\/dev\/null >\/dev\/tty 2>\/dev\/null &$/  sleep infinity <\/dev\/null >\/dev\/null 2>&1 &/ms'
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$dashboard" "the dashboard's logo" \
  's/^    while IFS= read -r line; do\n      printf .\\r%s%s%b%s%b\\n. "\$CLEAR_LINE" "\$pad" "\$GREEN" "\$line" "\$RESET"\n    done <"\$LOGO_PATH"$/    agentv-logo --prefix "\\r\$CLEAR_LINE\$pad"/m'
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$dashboard" "the finish screen's effect" \
  's/^      --final-gradient-stops 2 \\\n      >"\$TTY_PATH" 2>\/dev\/null \|\| \{\n        dashboard_log "logo effect skipped \(ttfx exited \$\?\)"$/      --final-gradient-stops 4 \\\n      >"\$TTY_PATH" 2>\/dev\/null || true; {\n        dashboard_log "AgenTV redraws its logo in its own colours"/m'
patch "$dashboard" "the finish screen's title" \
  's/title="Installed Omarchy"/title="Installed AgenTV"/'

echo "agentv-iso: added ${#added[@]} AgenTV packages to the offline mirror and the install, and AgenTV's logo and tagline"
