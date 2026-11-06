"""AgenTV's step in Omarchy's install: what the first screen hands over.

AgenTV's first screen on the USB stick leaves files for the installed box in
/root/agentv-handover, laid out the way they go on the box: the account's
marker, which says its password is one nobody knows yet. This copies them
onto the new system, owned by root. With nothing there (an autoinstall, or
Omarchy's own installer after Ctrl+C) it does nothing.

customize.sh puts this file in the installer and lists it among the install's
phases, right after SSH access, when the ISO is built.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

HANDOVER = Path("/root/agentv-handover")


def hand_over(source: Path, target: Path) -> list[Path]:
    """Copies source's files onto target, as root's, keeping their modes.
    Returns the paths it wrote on target. Links are left out."""
    written: list[Path] = []
    if not source.is_dir():
        return written
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            continue
        destination = target / path.relative_to(source)
        if path.is_dir():
            destination.mkdir(mode=0o755, parents=True, exist_ok=True)
        elif path.is_file():
            destination.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            shutil.copy2(path, destination)
            if os.geteuid() == 0:
                os.chown(destination, 0, 0)
            written.append(destination)
    return written


def agentv_handover(ctx) -> None:
    from .ui import info

    written = hand_over(HANDOVER, Path(ctx.target))
    for path in written:
        info(f"› AgenTV: /{path.relative_to(ctx.target)}")
