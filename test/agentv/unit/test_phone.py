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

ROOT = Path(__file__).resolve().parents[3]
HERE = ROOT / "configs/airootfs/usr/share/agentv-iso/first-screen"
sys.path.insert(0, str(HERE))

import agentv_phone as phone_side  # noqa: E402
import agentv_qr  # noqa: E402

DISKS = [
    {"path": "/dev/nvme0n1", "name": "nvme0n1", "model": "samsung ssd 970 evo", "size": "500 gb"},
    {"path": "/dev/sda", "name": "sda", "model": "wd blue hdd", "size": "2 tb"},
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

    def ask(self, method, path, body=None, host="127.0.0.1", headers=None, via="127.0.0.1"):
        connection = http.client.HTTPConnection(via, self.port, timeout=5)
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
        self.assertIn("erase and install", page)

    def test_a_phone_on_the_home_network_gets_it_without(self):
        # 127.0.0.2 reaches the same server, but isn't the hotspot's address.
        status, _, page = self.ask("GET", "/", host="127.0.0.2", via="127.0.0.2")
        self.assertEqual(status, 200)
        self.assertNotIn(self.phone.token, page)
        self.assertIn('const TOKEN = ""', page)

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

    def test_erase_and_install_needs_the_token_and_works_once(self):
        ask = self.run_dir / "ask.json"
        status, answer = self.ask_json("POST", "/api/first/install", {"disk": "/dev/sda"})
        self.assertEqual(status, 403)
        self.assertIn("scan the code on the tv", answer["error"])
        status, _ = self.ask_json("POST", "/api/first/install", {"disk": "/dev/sda", "token": "x" * 22})
        self.assertEqual(status, 403)
        self.assertFalse(ask.exists())

        status, _ = self.ask_json("POST", "/api/first/install", {"disk": "/dev/sdz", "token": self.phone.token})
        self.assertEqual(status, 400)
        self.assertFalse(ask.exists())

        status, answer = self.ask_json("POST", "/api/first/install", {"disk": "/dev/sda", "token": self.phone.token})
        self.assertEqual((status, answer), (200, {"ok": True}))
        self.assertEqual(json.loads(ask.read_text()), {"install": "/dev/sda"})

        ask.unlink()
        status, _ = self.ask_json("POST", "/api/first/install", {"disk": "/dev/sda", "token": self.phone.token})
        self.assertEqual(status, 409)
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
