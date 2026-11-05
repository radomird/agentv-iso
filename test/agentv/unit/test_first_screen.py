"""AgenTV's first screen on the USB stick, without a VM.

The answers it writes are checked against the ones Omarchy's own configurator
writes for the same disk, from the configurator in this repo, so an Omarchy
sync that changes them turns this red. The screen itself is driven through a
pseudo-terminal, the way a keyboard on the box drives it: Enter installs on
the highlighted disk, the arrows move, and Ctrl+C leaves for Omarchy's
installer with nothing written.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import fcntl
import json
import os
import pty
import struct
import termios
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = ROOT / "configs/airootfs/usr/share/agentv-iso/first-screen"
CONFIGURATOR = ROOT / "configs/airootfs/root/configurator"


def load(name: str, path: Path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    loader.exec_module(module)
    return module


screen = load("agentv_first_screen", HERE / "agentv-first-screen")
# The logo the ISO draws, from agentv-os's branding.
screen.LOGO = ROOT / "configs/airootfs/usr/share/agentv-iso/logo.ansi"
handover = load("agentv_handover", HERE / "agentv_handover.py")

DISKS = [
    screen.Disk("/dev/nvme0n1", 500107862016, "samsung ssd 970 evo"),
    screen.Disk("/dev/sda", 2000398934016, "wd blue hdd"),
]
HOTSPOT = {
    "mode": "hotspot",
    "ssid": "AgenTV-1a2b",
    "password": "abcdefghjk",
    "device": "wlan0",
    "qr": "WIFI:T:WPA;S:AgenTV-1a2b;P:abcdefghjk;;",
    "joined": False,
}


def plain(text: str) -> str:
    """The screen's text, one line per row it's drawn on, without colours.
    What's drawn on the same row (the disks and the phone's code) is joined
    left to right, with a wide gap between."""
    rows: dict[int, list[tuple[int, str]]] = {}
    for row, col, line in re.findall(r"\x1b\[(\d+);(\d+)H([^\x1b]*(?:\x1b\[[0-9;?]*m[^\x1b]*)*)", text):
        rows.setdefault(int(row), []).append((int(col), re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", line)))
    return "\n".join("    ".join(t for _, t in sorted(rows[r])) for r in sorted(rows))


def configurator_block(start: str, stop: str) -> str:
    """The configurator's own lines, from the first one starting with start
    up to the first line after it that starts with stop: that line itself
    too when stop is a heredoc's end, and not when it's the next function."""
    lines = CONFIGURATOR.read_text().splitlines()
    first = next(i for i, line in enumerate(lines) if line.startswith(start))
    last = next(i for i in range(first + 1, len(lines)) if lines[i].startswith(stop))
    return "\n".join(lines[first : last + 1] if stop in ("_EOF_", "fi") else lines[first:last])


class Answers(unittest.TestCase):
    def test_user_configuration_is_the_configurators_own(self):
        # The configurator's full-disk layout and its JSON, run by bash with
        # what the first screen picks, and lsblk answering for a 500 GB disk.
        # From the layout to the end of the JSON, which is the second heredoc.
        layout = configurator_block("# Setup partition layout", "if [[ $1 == \"dry\" ]]; then")
        mirrors = configurator_block("if [[ $iso_arch == aarch64 ]]; then", "fi")
        self.assertIn("limine_efi_binary", mirrors)
        size = 500107862016
        script = f"""
set -euo pipefail
lsblk() {{ echo {size}; }}
detect_kernel() {{ echo linux-omarchy; }}
iso_arch=x86_64
{mirrors}
disk=/dev/nvme0n1 encrypt_installation=false defer_provisioning=false
keyboard=us keyboard_input_method=none keyboard_xkb_layout= language=en
hostname=agentv timezone=UTC
OMARCHY_SETTINGS_PACKAGE=omarchy-settings OMARCHY_RUNTIME_PACKAGE=omarchy
set -- install
{layout}
"""
        with tempfile.TemporaryDirectory() as work:
            subprocess.run(["bash", "-c", script], cwd=work, check=True)
            theirs = json.loads(Path(work, "user_configuration.json").read_text())
        ours = screen.user_configuration("/dev/nvme0n1", size, "x86_64", "linux-omarchy")
        self.assertEqual(ours, theirs)

    def test_user_credentials_are_the_configurators_own(self):
        write_user_files = configurator_block("write_user_files() {", "# Show what a dry run")
        hashed = "$6$salt$abcdefghijklmnop"
        script = f"""
set -euo pipefail
{write_user_files}
encrypt_installation=false defer_provisioning=false
username=agentv password=never-shown password_hash='{hashed}'
write_user_files
"""
        with tempfile.TemporaryDirectory() as work:
            subprocess.run(["bash", "-c", script], cwd=work, check=True)
            theirs = json.loads(Path(work, "user_credentials.json").read_text())
            encrypt = Path(work, "user_encrypt_installation.txt").read_text()
        self.assertEqual(screen.user_credentials(hashed), theirs)
        self.assertEqual(encrypt, "false\n")

    @unittest.skipUnless(shutil.which("openssl"), "needs openssl")
    def test_writes_the_answers_and_the_handover(self):
        with tempfile.TemporaryDirectory() as work:
            old = screen.ANSWERS, screen.HANDOVER
            screen.ANSWERS, screen.HANDOVER = Path(work), Path(work) / "agentv-handover"
            try:
                screen.write_answers(DISKS[1])
            finally:
                screen.ANSWERS, screen.HANDOVER = old
            config = json.loads(Path(work, "user_configuration.json").read_text())
            credentials = json.loads(Path(work, "user_credentials.json").read_text())
            account = json.loads(Path(work, "agentv-handover/var/lib/agentv/account.json").read_text())
            mode = Path(work, "user_credentials.json").stat().st_mode & 0o777
            encrypt = Path(work, "user_encrypt_installation.txt").read_text()

        self.assertEqual(config["disk_config"]["device_modifications"][0]["device"], "/dev/sda")
        self.assertEqual(config["hostname"], "agentv")
        self.assertNotIn("disk_encryption", config["disk_config"])
        self.assertEqual(encrypt, "false\n")
        user = credentials["users"][0]
        self.assertEqual((user["username"], user["sudo"]), ("agentv", True))
        self.assertTrue(user["enc_password"].startswith("$6$"))
        self.assertEqual(user["enc_password"], credentials["root_enc_password"])
        self.assertNotIn("encryption_password", credentials)
        self.assertEqual(mode, 0o600)
        self.assertEqual(account, {"name": "agentv", "passwordKnown": False})

    def test_two_installs_never_share_a_password(self):
        if not shutil.which("openssl"):
            self.skipTest("needs openssl")
        self.assertNotEqual(screen.random_password_hash(), screen.random_password_hash())


class Disks(unittest.TestCase):
    def test_sizes_read_the_way_the_box_says(self):
        self.assertEqual(screen.size_label(500107862016), "500 gb")
        self.assertEqual(screen.size_label(2000398934016), "2 tb")
        self.assertEqual(screen.size_label(1500301910016), "1.5 tb")
        self.assertEqual(screen.size_label(42949672960), "43 gb")

    def test_names_join_vendor_and_model_like_the_configurator(self):
        self.assertEqual(screen.model_label("ATA     ", "WDC WD20EZRZ"), "ata wdc wd20ezrz")
        self.assertEqual(screen.model_label("Samsung", "Samsung SSD 970 EVO 500GB"), "samsung ssd 970 evo 500gb")
        self.assertEqual(screen.model_label("", "Samsung SSD 970 EVO"), "samsung ssd 970 evo")
        self.assertEqual(screen.model_label("0x1af4", ""), "")


class Drawing(unittest.TestCase):
    def test_step_one_with_two_disks(self):
        text = plain(screen.render(DISKS, 0, 120, 33))
        self.assertIn("1 of 12 · disk", text)
        self.assertIn("powered by omarchy", text)
        self.assertIn("install agentv on", text)
        self.assertRegex(text, r"› nvme0n1 +samsung ssd 970 evo +500 gb")
        self.assertRegex(text, r"sda +wd blue hdd +2 tb")
        self.assertIn("everything on it will be erased", text)
        self.assertIn("enter install", text)
        self.assertIn("↑ ↓ pick a disk", text)
        self.assertIn("ctrl+c omarchy's own installer", text)

    def test_no_omarchy_question(self):
        text = plain(screen.render(DISKS, 1, 120, 33)).lower()
        for word in ("keyboard", "username", "password", "hostname", "timezone", "time zone", "email", "language"):
            self.assertNotIn(word, text)

    def test_the_highlight_follows_the_arrows(self):
        text = plain(screen.render(DISKS, 1, 120, 33))
        self.assertRegex(text, r"› sda")
        self.assertNotRegex(text, r"› nvme0n1")

    def test_one_disk_has_no_arrows(self):
        text = plain(screen.render(DISKS[:1], 0, 120, 33))
        self.assertNotIn("pick a disk", text)

    def test_no_disk(self):
        text = plain(screen.render([], 0, 120, 33))
        self.assertIn("there's no disk to install agentv on", text)
        self.assertNotIn("enter install", text)
        self.assertIn("ctrl+c omarchy's own installer", text)

    def test_the_phones_code_beside_the_disks(self):
        for cols, rows in ((160, 50), (120, 33), (240, 67)):
            drawn = screen.render(DISKS, 0, cols, rows, HOTSPOT)
            text = plain(drawn)
            self.assertIn("or set it up from your phone", text, f"{cols}x{rows}")
            rows_drawn = [int(r) for r in re.findall(r"\x1b\[(\d+);\d+H", drawn)]
            self.assertLessEqual(max(rows_drawn), rows, f"{cols}x{rows}")
            self.assertIn("everything on it will be erased", text)

    def test_a_console_too_small_for_the_code_says_it_in_words(self):
        text = plain(screen.render(DISKS, 0, 80, 25, HOTSPOT))
        self.assertIn("or set it up from your phone: wi-fi AgenTV-1a2b, password abcdefghjk", text)

    def test_no_code_without_a_way_in(self):
        text = plain(screen.render(DISKS, 0, 160, 50, {"mode": "none", "qr": None}))
        self.assertNotIn("from your phone", text)

    def test_fits_a_small_console(self):
        drawn = screen.render(DISKS, 0, 80, 25)
        rows = [int(r) for r in re.findall(r"\x1b\[(\d+);\d+H", drawn)]
        self.assertLessEqual(max(rows), 25)
        self.assertIn("everything on it will be erased", plain(drawn))


class Keys(unittest.TestCase):
    """The whole screen in a pseudo-terminal, with two disks."""

    def drive(self, keys: list[bytes], phone: dict | None = None, asks: list[dict] | None = None) -> tuple[int, str, Path]:
        """Runs the screen with these keys pressed, and what the phone's side
        would write: phone.json before it starts, and each ask in turn."""
        work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, work, True)
        run = work / "run"
        run.mkdir()
        if phone:
            (run / "phone.json").write_text(json.dumps(phone))
        pid, fd = pty.fork()
        if pid == 0:  # the screen, with the pty as its console
            try:
                screen.ANSWERS = work / "answers"
                screen.HANDOVER = work / "answers/agentv-handover"
                screen.RUN = run
                screen.list_disks = lambda: list(DISKS)
                screen.console_font = lambda tty: None
                screen.random_password_hash = lambda: "$6$test$hash"
                screen.start_phone = lambda: None
                screen.stop_phone = lambda: None
                os._exit(screen.main(["agentv-first-screen"]))
            except BaseException:  # noqa: BLE001
                os._exit(99)
        # A TV's console at 1080p with Omarchy's 16 x 32 font.
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 33, 120, 0, 0))
        output = b""
        deadline = time.monotonic() + 10
        # Wait for the first drawing before pressing anything.
        while b"erased" not in output and time.monotonic() < deadline:
            if select.select([fd], [], [], 0.2)[0]:
                output += os.read(fd, 65536)
        for key in keys:
            os.write(fd, key)
            time.sleep(0.3)
        for ask in asks or []:
            (run / "ask.json").write_text(json.dumps(ask))
            time.sleep(1)
        status = None
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.2)[0]:
                try:
                    output += os.read(fd, 65536)
                except OSError:
                    pass
            done, code = os.waitpid(pid, os.WNOHANG)
            if done:
                status = os.waitstatus_to_exitcode(code)
                break
        os.close(fd)
        if status is None:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
        return status, output.decode("utf-8", "replace"), work / "answers"

    def test_enter_installs_on_the_highlighted_disk(self):
        status, _, work = self.drive([b"\r"])
        self.assertEqual(status, 0)
        config = json.loads((work / "user_configuration.json").read_text())
        self.assertEqual(config["disk_config"]["device_modifications"][0]["device"], "/dev/nvme0n1")

    def test_down_then_enter_picks_the_second(self):
        status, output, work = self.drive([b"\x1b[B", b"\r"])
        self.assertEqual(status, 0)
        config = json.loads((work / "user_configuration.json").read_text())
        self.assertEqual(config["disk_config"]["device_modifications"][0]["device"], "/dev/sda")
        self.assertIn("› sda", output)

    def test_ctrl_c_leaves_for_omarchys_installer_with_nothing_written(self):
        status, _, work = self.drive([b"\x03"])
        self.assertEqual(status, 1)
        self.assertEqual(sorted(p.name for p in work.iterdir()) if work.exists() else [], [])

    def test_the_phone_picks_and_installs(self):
        status, output, work = self.drive([], phone=HOTSPOT, asks=[{"pick": "/dev/sda"}, {"install": "/dev/sda"}])
        self.assertEqual(status, 0)
        config = json.loads((work / "user_configuration.json").read_text())
        self.assertEqual(config["disk_config"]["device_modifications"][0]["device"], "/dev/sda")
        self.assertIn("\u203a sda", output)
        handed = json.loads((work / "agentv-handover/etc/agentv/hotspot.json").read_text())
        self.assertEqual(handed, {"ssid": "AgenTV-1a2b", "password": "abcdefghjk"})
        self.assertEqual((work / "agentv-handover/etc/agentv/hotspot.json").stat().st_mode & 0o777, 0o600)

    def test_a_disk_the_tv_doesnt_list_is_ignored(self):
        status, _, work = self.drive([b"\x03"], phone=HOTSPOT, asks=[{"install": "/dev/sdz"}])
        self.assertEqual(status, 1)
        self.assertFalse((work / "user_configuration.json").exists())

    def test_enter_hands_the_hotspot_over_only_when_a_phone_is_on_it(self):
        _, _, work = self.drive([b"\r"], phone=HOTSPOT)
        self.assertFalse((work / "agentv-handover/etc/agentv/hotspot.json").exists())
        self.assertTrue((work / "agentv-handover/var/lib/agentv/account.json").exists())
        _, _, work = self.drive([b"\r"], phone={**HOTSPOT, "joined": True})
        self.assertTrue((work / "agentv-handover/etc/agentv/hotspot.json").exists())

    def test_other_keys_do_nothing(self):
        status, _, work = self.drive([b"x", b"\x1b[C", b"\x1b", b"\x03"])
        self.assertEqual(status, 1)
        self.assertFalse((work / "user_configuration.json").exists())


class Handover(unittest.TestCase):
    def test_copies_the_files_with_their_modes(self):
        with tempfile.TemporaryDirectory() as source, tempfile.TemporaryDirectory() as target:
            marker = Path(source, "var/lib/agentv/account.json")
            marker.parent.mkdir(parents=True)
            marker.write_text("{}\n")
            marker.chmod(0o644)
            secret = Path(source, "etc/agentv/private")
            secret.parent.mkdir(parents=True)
            secret.write_text("x\n")
            secret.chmod(0o600)
            Path(source, "link").symlink_to("/etc/passwd")
            Path(target, "var/lib/agentv").mkdir(parents=True)

            written = handover.hand_over(Path(source), Path(target))

            self.assertEqual(
                sorted(str(p.relative_to(target)) for p in written),
                ["etc/agentv/private", "var/lib/agentv/account.json"],
            )
            self.assertEqual(Path(target, "var/lib/agentv/account.json").read_text(), "{}\n")
            self.assertEqual(Path(target, "etc/agentv/private").stat().st_mode & 0o777, 0o600)
            self.assertFalse(Path(target, "link").exists())

    def test_nothing_to_hand_over(self):
        with tempfile.TemporaryDirectory() as target:
            self.assertEqual(handover.hand_over(Path(target, "missing"), Path(target)), [])


if __name__ == "__main__":
    unittest.main()
