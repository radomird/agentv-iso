"""The phone's way through the first screen, without a VM: the QR code the TV
draws, and the page and token on the live system (agentv_phone.py).

The server runs on a free port on this machine. A request to the address it
takes for the hotspot's is a phone on the hotspot; any other is a phone on
the home network.
"""

from __future__ import annotations

import http.client
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
HERE = ROOT / "configs/airootfs/usr/share/agentv-iso/first-screen"
sys.path.insert(0, str(HERE))

import agentv_phone as phone_side  # noqa: E402
import agentv_qr  # noqa: E402

DISKS = [
    {"path": "/dev/nvme0n1", "name": "nvme0n1", "model": "Samsung SSD 970 EVO", "size": "500 GB"},
    {"path": "/dev/sda", "name": "sda", "model": "WD Blue HDD", "size": "2 TB"},
]


def decode(modules: list[list[bool]]) -> str | None:
    """What zbarimg reads off the code, drawn dark on light."""
    if not shutil.which("zbarimg"):
        return None
    border, scale = 4, 6
    n = len(modules) + 2 * border
    rows = []
    for y in range(n):
        row = bytearray()
        for x in range(n):
            mx, my = x - border, y - border
            dark = 0 <= mx < len(modules) and 0 <= my < len(modules) and modules[my][mx]
            row += bytes([0 if dark else 255]) * scale
        rows += [bytes(row)] * scale
    with tempfile.NamedTemporaryFile(suffix=".pgm") as image:
        image.write(b"P5 %d %d 255\n" % (n * scale, n * scale) + b"".join(rows))
        image.flush()
        out = subprocess.run(["zbarimg", "-q", "--raw", image.name], capture_output=True, text=True)
    return out.stdout.rstrip("\n")


class Code(unittest.TestCase):
    def test_reed_solomon_matches_the_standards_worked_example(self):
        # ISO/IEC 18004's example: version 1-M, "01234567".
        data = [0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11]
        self.assertEqual(
            agentv_qr.rs_remainder(data, 10), [0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55]
        )

    def test_format_bits_are_the_standards(self):
        self.assertEqual(agentv_qr.format_bits(0), 0b101010000010010)
        self.assertEqual(agentv_qr.format_bits(5), 0b100000011001110)

    def test_sizes(self):
        self.assertEqual(len(agentv_qr.matrix("WIFI:T:WPA;S:AgenTV-1a2b;P:abcdefghjk;;")), 29)
        self.assertEqual(len(agentv_qr.matrix("http://192.168.100.200/?t=" + "x" * 22)), 33)
        with self.assertRaises(agentv_qr.TooLong):
            agentv_qr.matrix("x" * 107)

    @unittest.skipUnless(shutil.which("zbarimg"), "needs zbarimg")
    def test_a_phone_reads_back_what_it_says(self):
        for text in (
            "WIFI:T:WPA;S:AgenTV-1a2b;P:abcdefghjk;;",
            "http://192.168.100.200/?t=Kx3_aZ9-QwErTyUiOpAsDf",
            "a",
            "x" * 60,
            "z" * 106,
        ):
            self.assertEqual(decode(agentv_qr.matrix(text)), text)

    @unittest.skipUnless(shutil.which("zbarimg"), "needs zbarimg")
    def test_the_consoles_half_blocks_read_back_too(self):
        # The TV's drawing, turned back into modules: light is a drawn half.
        screen = sys.modules.get("agentv_first_screen")
        if screen is None:
            from test_first_screen import screen  # noqa: PLC0415
        text = "WIFI:T:WPA;S:AgenTV-1a2b;P:abcdefghjk;;"
        lines = [line.replace("\x1b[97m", "").replace("\x1b[0m", "") for line in screen.qr_lines(text)]
        modules = []
        for line in lines:
            top = [c in "█▀" for c in line]
            bottom = [c in "█▄" for c in line]
            modules += [[not light for light in top], [not light for light in bottom]]
        # Drop the quiet zone the console draws, and the half row past it.
        border = 2
        size = len(agentv_qr.matrix(text))
        modules = [row[border : border + size] for row in modules[border : border + size]]
        self.assertEqual(decode(modules), text)

    def test_wifi_escapes_what_the_format_reserves(self):
        self.assertEqual(agentv_qr.wifi("a;b", 'p:w,"x\\'), 'WIFI:T:WPA;S:a\\;b;P:p\\:w\\,\\"x\\\\;;')


class Page(unittest.TestCase):
    def setUp(self):
        self.run_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.run_dir, True)
        (self.run_dir / "screen.json").write_text(json.dumps({"step": 1, "disks": DISKS, "selected": "/dev/nvme0n1"}))
        self.saved = phone_side.RUN, phone_side.ADDRESS, phone_side.PORT
        phone_side.RUN = self.run_dir
        phone_side.ADDRESS = "127.0.0.1"  # "the hotspot"
        phone_side.PORT = 0
        self.phone = phone_side.Phone()
        self.server = phone_side.serve(self.phone)
        self.port = self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        phone_side.RUN, phone_side.ADDRESS, phone_side.PORT = self.saved

    def ask(self, method, path, body=None, host="127.0.0.1", headers=None, via="127.0.0.1", source=None):
        # "source" is the phone's own address, when it matters which it is.
        connection = http.client.HTTPConnection(
            via, self.port, timeout=5, source_address=(source, 0) if source else None
        )
        payload = json.dumps(body).encode() if body is not None else None
        connection.request(method, path, body=payload, headers={"Host": host, **(headers or {})})
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, response.getheader("Location"), data.decode()

    def ask_json(self, *args, **kwargs):
        status, _, data = self.ask(*args, **kwargs)
        return status, json.loads(data) if data else {}

    def test_a_phone_on_the_hotspot_gets_the_page_with_the_token(self):
        status, _, page = self.ask("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn(f'const TOKEN = "{self.phone.token}"', page)
        self.assertIn("Erase and install", page)

    def test_a_phone_on_the_home_network_gets_it_without(self):
        # 127.0.0.2 reaches the same server, but isn't the hotspot's address.
        status, _, page = self.ask("GET", "/", host="127.0.0.2", via="127.0.0.2")
        self.assertEqual(status, 200)
        self.assertNotIn(self.phone.token, page)
        self.assertIn('const TOKEN = ""', page)

    def test_a_phone_with_an_address_from_outside_the_hotspot_isnt_on_it(self):
        # It asks the hotspot's address, but its own address (127.0.1.1) isn't
        # in the hotspot's network (127.0.0.0/24 here): the home network.
        status, _, page = self.ask("GET", "/", source="127.0.1.1")
        self.assertEqual(status, 200)
        self.assertNotIn(self.phone.token, page)
        self.assertIn('const TOKEN = ""', page)
        status, state = self.ask_json("GET", "/api/first", source="127.0.1.1")
        self.assertEqual(status, 403)
        self.assertNotIn("disks", state)
        status, location, _ = self.ask("GET", "/generate_204", host="connectivitycheck.gstatic.com", source="127.0.1.1")
        self.assertEqual((status, location), (404, None))
        # With the token from the TV's code it still gets the disks.
        status, state = self.ask_json(
            "GET", "/api/first", source="127.0.1.1", headers={"X-AgenTV-Token": self.phone.token}
        )
        self.assertEqual(status, 200)

    def test_a_phone_with_an_address_the_hotspot_gave_is_on_it(self):
        status, _, page = self.ask("GET", "/", source="127.0.0.9")
        self.assertEqual(status, 200)
        self.assertIn(f'const TOKEN = "{self.phone.token}"', page)
        status, state = self.ask_json("GET", "/api/first", source="127.0.0.9")
        self.assertEqual(status, 200)
        self.assertEqual([d["name"] for d in state["disks"]], ["nvme0n1", "sda"])

    def test_which_addresses_are_the_hotspots(self):
        saved = phone_side.ADDRESS
        phone_side.ADDRESS = "10.42.0.1"
        try:
            for address in ("10.42.0.10", "10.42.0.250", "::ffff:10.42.0.77"):
                self.assertTrue(phone_side.in_hotspot_network(address), address)
            for address in ("10.42.1.10", "192.168.1.20", "::ffff:192.168.1.20", "fe80::1", "", None, "phone"):
                self.assertFalse(phone_side.in_hotspot_network(address), address)
        finally:
            phone_side.ADDRESS = saved

    def test_dnsmasq_hands_out_addresses_from_the_hotspots_own_network(self):
        saved = phone_side.ADDRESS, phone_side.PREFIX
        try:
            for address, prefix, wanted in (
                ("10.42.0.1", 24, "10.42.0.10,10.42.0.250,255.255.255.0"),
                ("192.168.77.1", 24, "192.168.77.10,192.168.77.250,255.255.255.0"),
                ("172.20.4.1", 22, "172.20.4.10,172.20.7.250,255.255.252.0"),
                ("10.9.8.1", 28, "10.9.8.1,10.9.8.14,255.255.255.240"),
            ):
                phone_side.ADDRESS, phone_side.PREFIX = address, prefix
                first, last, _ = phone_side.dhcp_range().split(",")
                self.assertEqual(phone_side.dhcp_range(), wanted)
                # What it hands out is what the page takes for a phone on the hotspot.
                self.assertTrue(phone_side.in_hotspot_network(first), first)
                self.assertTrue(phone_side.in_hotspot_network(last), last)
        finally:
            phone_side.ADDRESS, phone_side.PREFIX = saved

    def test_the_hotspot_starts_dnsmasq_with_that_range(self):
        # The access point's own start, with every command it runs stood in for.
        started = []

        class Started:
            returncode = None

            def __init__(self, args, **_):
                started.append(args)

            def poll(self):
                return None

        with (
            mock.patch.object(phone_side, "ADDRESS", "192.168.77.1"),
            mock.patch.object(phone_side, "NETWORKD", self.run_dir / "networkd" / "hotspot.network"),
            mock.patch.object(phone_side, "netdev_of", lambda phy: "wlan0"),
            mock.patch.object(phone_side, "run", lambda args, timeout=20: "type AP" if args[:2] == ["iw", "dev"] else ""),
            mock.patch.object(phone_side.subprocess, "Popen", Started),
            mock.patch.object(phone_side.time, "sleep", lambda seconds: None),
        ):
            self.assertTrue(phone_side.Hotspot().start("phy0"))
        dnsmasq = next(args for args in started if args[0] == "dnsmasq")
        self.assertIn("--dhcp-range=192.168.77.10,192.168.77.250,255.255.255.0,10m", dnsmasq)
        self.assertEqual([arg for arg in dnsmasq if "10.42." in arg], [])

    def test_every_other_name_on_the_hotspot_goes_to_the_page(self):
        status, location, _ = self.ask("GET", "/hotspot-detect.html", host="captive.apple.com")
        self.assertEqual((status, location), (302, "http://127.0.0.1/"))
        status, location, _ = self.ask("GET", "/generate_204", host="connectivitycheck.gstatic.com")
        self.assertEqual((status, location), (302, "http://127.0.0.1/"))

    def test_the_disks_come_from_the_tv(self):
        status, state = self.ask_json("GET", "/api/first")
        self.assertEqual(status, 200)
        self.assertEqual([d["name"] for d in state["disks"]], ["nvme0n1", "sda"])
        self.assertEqual((state["step"], state["selected"]), (1, "/dev/nvme0n1"))

    def test_f11_the_home_network_gets_no_disks_without_the_token(self):
        # 127.0.0.2 isn't the hotspot's address, so this is the home network.
        status, state = self.ask_json("GET", "/api/first", host="127.0.0.2", via="127.0.0.2")
        self.assertEqual(status, 403)
        self.assertNotIn("disks", state)
        self.assertNotIn("step", state)
        self.assertEqual(state["error"], "Scan the code on your TV to start")
        status, state = self.ask_json(
            "GET", "/api/first", host="127.0.0.2", via="127.0.0.2", headers={"X-AgenTV-Token": "x" * 22}
        )
        self.assertEqual(status, 403)
        self.assertNotIn("disks", state)

    def test_f11_the_phone_that_scanned_the_code_still_gets_them_there(self):
        token = {"X-AgenTV-Token": self.phone.token}
        status, state = self.ask_json("GET", "/api/first", host="127.0.0.2", via="127.0.0.2", headers=token)
        self.assertEqual(status, 200)
        self.assertEqual([d["name"] for d in state["disks"]], ["nvme0n1", "sda"])
        # And through the install, after the token has erased once.
        self.ask_json("POST", "/api/first/install", {"disk": "/dev/sda", "token": self.phone.token})
        (self.run_dir / "screen.json").write_text(json.dumps({"step": 2, "disks": DISKS, "installing": "/dev/sda"}))
        status, state = self.ask_json("GET", "/api/first", host="127.0.0.2", via="127.0.0.2", headers=token)
        self.assertEqual((status, state["step"]), (200, 2))

    def test_the_page_says_installing_agentv(self):
        # The words a phone reads, in sentence case, and never Omarchy's name
        # for what it installs.
        page = (HERE / "phone.html").read_text()
        for words in (
            "<h1>Install AgenTV on</h1>",
            "Everything on it will be erased",
            "<h1>Installing AgenTV</h1>",
            "Your TV restarts on its own. Keep this page open.",
            "No disk found. Plug one in.",
            "Scan the code on your TV to start",
        ):
            self.assertIn(words, page)
        self.assertNotIn("omarchy", page.lower())

    def test_the_page_sends_its_token_when_it_asks_for_the_disks(self):
        page = (HERE / "phone.html").read_text()
        self.assertIn('fetch("/api/first", { cache: "no-store", headers: TOKEN ? { "X-AgenTV-Token": TOKEN } : {} })', page)

    def test_erase_and_install_needs_the_token_and_works_once(self):
        ask = self.run_dir / "ask.json"
        status, answer = self.ask_json("POST", "/api/first/install", {"disk": "/dev/sda"})
        self.assertEqual(status, 403)
        self.assertEqual(answer["error"], "Scan the code on your TV to start")
        status, _ = self.ask_json("POST", "/api/first/install", {"disk": "/dev/sda", "token": "x" * 22})
        self.assertEqual(status, 403)
        self.assertFalse(ask.exists())

        status, answer = self.ask_json("POST", "/api/first/install", {"disk": "/dev/sdz", "token": self.phone.token})
        self.assertEqual((status, answer["error"]), (400, "Couldn't find that disk"))
        self.assertFalse(ask.exists())

        status, answer = self.ask_json("POST", "/api/first/install", {"disk": "/dev/sda", "token": self.phone.token})
        self.assertEqual((status, answer), (200, {"ok": True}))
        self.assertEqual(json.loads(ask.read_text()), {"install": "/dev/sda"})

        ask.unlink()
        status, answer = self.ask_json("POST", "/api/first/install", {"disk": "/dev/sda", "token": self.phone.token})
        self.assertEqual((status, answer["error"]), (409, "Already installing"))
        self.assertFalse(ask.exists())
        status, _, page = self.ask("GET", "/")
        self.assertNotIn(self.phone.token, page)

    def test_picking_moves_the_tvs_highlight(self):
        status, _ = self.ask_json("POST", "/api/first/pick", {"disk": "/dev/sda", "token": self.phone.token})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads((self.run_dir / "ask.json").read_text()), {"pick": "/dev/sda"})

    def test_nothing_once_the_tv_is_installing(self):
        (self.run_dir / "screen.json").write_text(json.dumps({"step": 2, "disks": DISKS, "installing": "/dev/sda"}))
        status, _ = self.ask_json("POST", "/api/first/install", {"disk": "/dev/sda", "token": self.phone.token})
        self.assertEqual(status, 409)

    def test_only_from_its_own_page(self):
        status, _ = self.ask_json(
            "POST", "/api/first/install", {"disk": "/dev/sda", "token": self.phone.token},
            headers={"Origin": "http://elsewhere.example"},
        )
        self.assertEqual(status, 403)
        self.assertFalse((self.run_dir / "ask.json").exists())


class Radios(unittest.TestCase):
    def test_a_radio_that_can_be_an_access_point(self):
        info = (
            "Wiphy phy0\n\tmax # scan SSIDs: 20\n\tSupported interface modes:\n"
            "\t\t * IBSS\n\t\t * managed\n\t\t * AP\n\t\t * AP/VLAN\n\t\t * monitor\n\tBand 1:\n"
        )
        self.assertTrue(phone_side.supports_access_point(info))

    def test_one_that_cant(self):
        info = "Wiphy phy1\n\tSupported interface modes:\n\t\t * managed\n\t\t * AP/VLAN\n\t\t * monitor\n\tBand 1:\n"
        self.assertFalse(phone_side.supports_access_point(info))


if __name__ == "__main__":
    unittest.main()
