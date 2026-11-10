"""The phone's way through AgenTV's first screen on the USB stick.

The first screen starts this in the background. It opens the live system's
own Wi-Fi network, AgenTV-<4 characters>, the way the installed box opens its
setup hotspot: an access point with a random password, addresses from
dnsmasq, and every name pointing at the box, so a phone that joins opens the
page on its own. The TV shows a QR code with the network's name and
password, and the page on the phone lists the disks, with "erase and
install".

Only the phone that scanned the code can erase a disk. There's one token per
boot, and "erase and install" needs it. A phone on the hotspot gets it with
the page, since joining took the password from the TV's code. With no Wi-Fi
card that can host a network, the code is the box's address on the home
network with the token in it, and a phone there only gets in with that: it
sees no disks without it. The token erases once.

It keeps running through the install, so the phone keeps its page until the
box restarts. The installed box opens the same network with the same
password (the first screen hands them over), so the phone rejoins it by
itself.

It talks to the first screen through files in /run/agentv-first-screen:
  phone.json   what the TV shows: the network, or the address (written here)
  screen.json  the disks, which one is picked, and the step (the TV's)
  ask.json     what the phone asked for: pick a disk, or install (written here)

Usage: agentv_phone.py
"""

from __future__ import annotations

import hmac
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from agentv_qr import wifi  # noqa: E402

RUN = Path(os.environ.get("AGENTV_FIRST_SCREEN_RUN", "/run/agentv-first-screen"))
PAGE = HERE / "phone.html"
ADDRESS = os.environ.get("AGENTV_FIRST_SCREEN_ADDRESS", "10.42.0.1")
PORT = int(os.environ.get("AGENTV_FIRST_SCREEN_PORT", "80"))
NETWORKD = Path(os.environ.get("AGENTV_FIRST_SCREEN_NETWORKD", "/run/systemd/network/10-agentv-first-screen.network"))
# How often it looks for a Wi-Fi card and the home network again: a card's
# firmware, a USB dongle or the cable's address can come late.
LOOK_SECONDS = 3
MAX_BODY = 4096


def run(args: list[str], timeout: int = 20) -> str:
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout if result.returncode == 0 else ""


def log(text: str) -> None:
    print(f"agentv-phone: {text}", flush=True)


def write_json(path: Path, value: object, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.next")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as out:
        json.dump(value, out)
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def random_text(alphabet: str, length: int) -> str:
    return "".join(secrets.choice(alphabet) for _ in range(length))


# --- The hotspot -----------------------------------------------------------------


def supports_access_point(info: str) -> bool:
    """Whether iw phy <phy> info lists AP among its interface modes."""
    modes = re.search(r"Supported interface modes:\n((?:\t\t\t?\s*\* .*\n)+)", info)
    return bool(modes and re.search(r"\* AP$", modes.group(1), re.M))


def access_point_phy() -> str:
    """The first radio that can be an access point, or nothing."""
    try:
        phys = sorted(p.name for p in Path("/sys/class/ieee80211").iterdir())
    except OSError:
        return ""
    for phy in phys:
        if supports_access_point(run(["iw", "phy", phy, "info"])):
            return phy
    return ""


def netdev_of(phy: str) -> str:
    for link in sorted(Path("/sys/class/net").glob("*/phy80211/name")):
        try:
            if link.read_text().strip() == phy:
                return link.parent.parent.name
        except OSError:
            continue
    return ""


class Hotspot:
    def __init__(self) -> None:
        self.dnsmasq: subprocess.Popen | None = None
        self.supplicant: subprocess.Popen | None = None
        self.device = ""
        self.ssid = ""
        self.password = ""
        self.tries = 0

    def start(self, phy: str) -> bool:
        """One try at opening the network on this radio. A try that fails
        leaves iwd stopped and the radio's interface in place, so the next
        one starts from the same state."""
        self.tries += 1
        # iwd runs the live system's Wi-Fi, as a client. The access point is
        # wpa_supplicant's, as NetworkManager's is on the installed box.
        run(["systemctl", "stop", "iwd.service"])
        device = netdev_of(phy)
        if not device:
            run(["iw", "phy", phy, "interface", "add", "agentv0", "type", "managed"])
            device = netdev_of(phy)
        if not device:
            log(f"{phy} has no network device to open the hotspot on")
            return False
        # systemd-networkd would ask for an address on it, from itself.
        NETWORKD.parent.mkdir(parents=True, exist_ok=True)
        NETWORKD.write_text(f"[Match]\nName={device}\n\n[Link]\nUnmanaged=yes\n")
        run(["networkctl", "reload"])

        self.ssid = "AgenTV-" + random_text("0123456789abcdef", 4)
        self.password = random_text("abcdefghjkmnpqrstuvwxyz23456789", 10)
        conf = RUN / "hotspot.conf"
        fd = os.open(conf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as out:
            out.write(
                "network={\n"
                f'  ssid="{self.ssid}"\n'
                "  mode=2\n  frequency=2437\n  key_mgmt=WPA-PSK\n  proto=RSN\n"
                "  pairwise=CCMP\n  group=CCMP\n"
                f'  psk="{self.password}"\n'
                "}\n"
            )
        run(["ip", "addr", "flush", "dev", device])
        run(["ip", "link", "set", device, "up"])
        self.stop_supplicant()
        with open(RUN / "wpa_supplicant.log", "a") as output:
            self.supplicant = subprocess.Popen(
                ["wpa_supplicant", "-i", device, "-c", str(conf)], stdin=subprocess.DEVNULL, stdout=output, stderr=output
            )
        for _ in range(60):
            if "type AP" in run(["iw", "dev", device, "info"]) or self.supplicant.poll() is not None:
                break
            time.sleep(0.5)
        if "type AP" not in run(["iw", "dev", device, "info"]):
            log(f"{device} on {phy} didn't become an access point (try {self.tries}); iw dev says:")
            log(run(["iw", "dev"]).strip() or "(nothing)")
            self.stop_supplicant()
            return False
        run(["ip", "addr", "add", f"{ADDRESS}/24", "dev", device])
        leases = RUN / "dnsmasq.leases"
        leases.unlink(missing_ok=True)
        dnsmasq_log = open(RUN / "dnsmasq.log", "a")
        self.dnsmasq = subprocess.Popen(
            [
                "dnsmasq", "--keep-in-foreground", "--conf-file=/dev/null", "--no-resolv", "--no-hosts", "--no-poll",
                f"--interface={device}", "--except-interface=lo", "--bind-interfaces",
                "--dhcp-range=10.42.0.10,10.42.0.250,255.255.255.0,10m", "--dhcp-authoritative",
                f"--dhcp-option=option:router,{ADDRESS}", f"--dhcp-option=option:dns-server,{ADDRESS}",
                f"--dhcp-option=114,http://{ADDRESS}/",
                f"--address=/#/{ADDRESS}", f"--dhcp-leasefile={leases}", "--log-facility=-", "--log-dhcp",
            ],
            stdin=subprocess.DEVNULL,
            stdout=dnsmasq_log,
            stderr=dnsmasq_log,
        )
        dnsmasq_log.close()
        time.sleep(1)
        if self.dnsmasq.poll() is not None:
            log(f"dnsmasq stopped as it started (exit {self.dnsmasq.returncode}); see dnsmasq.log")
            self.dnsmasq = None
            self.stop_supplicant()
            return False
        self.device = device
        log(f"{self.ssid} is on {device}, with the page at http://{ADDRESS}/")
        return True

    def joined(self) -> bool:
        try:
            return (RUN / "dnsmasq.leases").stat().st_size > 0
        except OSError:
            return False

    def stop_supplicant(self) -> None:
        if self.supplicant and self.supplicant.poll() is None:
            self.supplicant.terminate()
            try:
                self.supplicant.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.supplicant.kill()
        self.supplicant = None

    def stop(self) -> None:
        """Everything put back, for Omarchy's installer after Ctrl+C."""
        if self.dnsmasq:
            self.dnsmasq.terminate()
            self.dnsmasq = None
        self.stop_supplicant()
        if self.device:
            run(["ip", "addr", "flush", "dev", self.device])
        NETWORKD.unlink(missing_ok=True)
        run(["networkctl", "reload"])
        run(["systemctl", "start", "iwd.service"])
        self.device = ""


def home_address(skip: str = "") -> str:
    """The box's address on the home network, by cable, or nothing."""
    for line in run(["ip", "-4", "-o", "addr", "show", "scope", "global"]).splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[1] != skip and parts[2] == "inet":
            return parts[3].split("/")[0]
    return ""


# --- What the phone asks ---------------------------------------------------------


class Phone:
    """The token, and what the TV shows. Shared by the server's threads."""

    def __init__(self) -> None:
        self.token = secrets.token_urlsafe(16)
        self.spent = False
        self.lock = threading.Lock()

    def check(self, token: object) -> bool:
        return isinstance(token, str) and hmac.compare_digest(token.encode(), self.token.encode())


def screen() -> dict:
    return read_json(RUN / "screen.json")


def disk_paths(state: dict) -> list[str]:
    return [d.get("path") for d in state.get("disks", []) if isinstance(d, dict)]


def make_handler(phone: Phone):
    page = PAGE.read_text(encoding="utf-8")

    class Handler(BaseHTTPRequestHandler):
        server_version = "agentv"
        sys_version = ""

        def log_message(self, *_args) -> None:
            pass

        def on_hotspot(self) -> bool:
            return self.connection.getsockname()[0] == ADDRESS

        def send(self, status: int, body: bytes, kind: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def json(self, status: int, value: dict) -> None:
            self.send(status, json.dumps(value).encode(), "application/json")

        def captive(self) -> bool:
            """On the hotspot, a phone asking for any other name (iOS's and
            Android's "am I online" pages) is sent to the page."""
            host = (self.headers.get("Host") or "").split(":")[0]
            if self.on_hotspot() and host != ADDRESS:
                self.send_response(302)
                self.send_header("Location", f"http://{ADDRESS}/")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return True
            return False

        def do_GET(self) -> None:  # noqa: N802
            if self.captive():
                return
            path = self.path.split("?")[0]
            if path in ("/", "/index.html"):
                token = phone.token if self.on_hotspot() and not phone.spent else ""
                self.send(200, page.replace("{{TOKEN}}", token).encode(), "text/html; charset=utf-8")
            elif path == "/api/first":
                # The disks and the step are for the phone that scanned the
                # TV's code: one on the hotspot, or one that has the token.
                # Anything else on the home network gets no list.
                if not self.on_hotspot() and not phone.check(self.headers.get("X-AgenTV-Token")):
                    self.json(403, {"ok": False, "error": "scan the code on the tv to set it up from this phone"})
                    return
                state = screen()
                self.json(200, {
                    "step": state.get("step", 1),
                    "disks": state.get("disks", []),
                    "selected": state.get("selected"),
                    "installing": state.get("installing"),
                })
            else:
                self.json(404, {"ok": False, "error": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            if self.captive():
                return
            origin = self.headers.get("Origin")
            if origin is not None and origin != f"http://{self.headers.get('Host')}":
                self.json(403, {"ok": False, "error": "not from the setup page"})
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = MAX_BODY + 1
            if length > MAX_BODY:
                self.json(413, {"ok": False, "error": "too long"})
                return
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                body = None
            if not isinstance(body, dict):
                self.json(400, {"ok": False, "error": "not json"})
                return
            path = self.path.split("?")[0]
            if path not in ("/api/first/pick", "/api/first/install"):
                self.json(404, {"ok": False, "error": "not found"})
                return
            with phone.lock:
                if phone.spent or screen().get("step", 1) != 1:
                    self.json(409, {"ok": False, "error": "it's installing already"})
                    return
                if not phone.check(body.get("token")):
                    self.json(403, {"ok": False, "error": "scan the code on the tv to set it up from this phone"})
                    return
                disk = body.get("disk")
                if disk not in disk_paths(screen()):
                    self.json(400, {"ok": False, "error": "that disk isn't on the tv's list"})
                    return
                if path.endswith("/install"):
                    phone.spent = True
                    write_json(RUN / "ask.json", {"install": disk})
                    log(f"a phone asked to erase and install on {disk}")
                else:
                    write_json(RUN / "ask.json", {"pick": disk})
            self.json(200, {"ok": True})

    return Handler


# --- Running ---------------------------------------------------------------------


def serve(phone: Phone) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("", PORT), make_handler(phone))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main() -> int:
    RUN.mkdir(parents=True, exist_ok=True, mode=0o755)
    (RUN / "phone.pid").write_text(f"{os.getpid()}\n")
    phone = Phone()
    hotspot = Hotspot()

    def stop(*_args) -> None:
        hotspot.stop()
        (RUN / "phone.json").unlink(missing_ok=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)
    server = serve(phone)
    log(f"the page is on port {PORT}")

    shown: dict = {}
    while True:
        if not hotspot.device and screen().get("step", 1) == 1:
            phy = access_point_phy()
            if phy:
                hotspot.start(phy)
        if hotspot.device:
            info = {
                "mode": "hotspot",
                "ssid": hotspot.ssid,
                "password": hotspot.password,
                "device": hotspot.device,
                "qr": wifi(hotspot.ssid, hotspot.password),
                "joined": hotspot.joined(),
            }
        elif address := home_address():
            url = f"http://{address}/?t={phone.token}" if PORT == 80 else f"http://{address}:{PORT}/?t={phone.token}"
            info = {"mode": "home", "address": address, "qr": url, "joined": False}
        else:
            info = {"mode": "none", "qr": None, "joined": False}
        if info != shown:
            write_json(RUN / "phone.json", info)
            shown = info
        time.sleep(LOOK_SECONDS)
    server.shutdown()  # not reached


if __name__ == "__main__":
    sys.exit(main())
