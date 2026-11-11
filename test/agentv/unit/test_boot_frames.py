"""The boot check's rule for the black as the TV session takes the screen.

frames.py says what each recorded frame is with ImageMagick and OCR. Here
each frame's kind and size are given instead, so only the rule is tested:
when the screen changes resolution after the splash, one black stretch
already at the session's size counts as that change, up to its limit. Black
at the splash's size is the splash going early, and always fails.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("agentv_frames", ROOT / "test/agentv/image/frames.py")
frames = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frames)

SPLASH, SESSION = "1280x800", "1920x1080"


def boot(*stretches):
    """Runs the analysis on a boot made of (kind, size, seconds) stretches,
    after the firmware's own screen. Returns its verdict and exit status."""
    with tempfile.TemporaryDirectory() as out:
        kinds, sizes, recorded = {}, {}, []
        t = 2.0
        for n, (kind, size, seconds) in enumerate([("firmware", SPLASH, 2.0), *stretches], 1):
            name = f"frame-{n:04d}.png"
            Path(out, name).touch()
            kinds[name], sizes[name] = kind, size
            start = 0.0 if kind == "firmware" else t
            recorded.append({"file": name, "t": start, "until": round(start + seconds - 0.1, 3)})
            t = start + seconds
        Path(out, "index.json").write_text(json.dumps({"frames": recorded, "events": [{"event": "boot loader", "t": 1.0}]}))
        real = frames.classify, frames.size
        frames.classify = lambda path, work, background, home: (kinds[os.path.basename(path)], "")
        frames.size = lambda path: sizes[os.path.basename(path)]
        try:
            with redirect_stdout(io.StringIO()):
                status = frames.analyse(SimpleNamespace(out=out, background="#1a1b26", home="home"))
        finally:
            frames.classify, frames.size = real
        return json.loads(Path(out, "timeline.json").read_text())["verdict"], status


class SessionBlack(unittest.TestCase):
    def test_black_at_the_session_size_is_the_change_of_resolution(self):
        verdict, status = boot(
            ("splash", SPLASH, 9.0),
            ("black", SESSION, 4.5),
            ("background", SESSION, 3.0),
            ("splash", SESSION, 10.0),
            ("home", SESSION, 5.0),
        )
        self.assertEqual(status, 0, verdict)
        self.assertEqual(verdict["gaps"], [])
        self.assertEqual(verdict["session_black_seconds"], 4.5)
        self.assertEqual(verdict["session_resized"], f"{SPLASH} to {SESSION}")

    def test_black_longer_than_the_limit_is_a_gap(self):
        verdict, status = boot(
            ("splash", SPLASH, 9.0),
            ("black", SESSION, frames.SESSION_RESIZE_S + 0.5),
            ("background", SESSION, 3.0),
            ("home", SESSION, 5.0),
        )
        self.assertEqual(status, 1)
        self.assertEqual(len(verdict["gaps"]), 1, verdict)

    def test_black_at_the_splash_size_is_the_splash_going_early(self):
        verdict, status = boot(
            ("splash", SPLASH, 9.0),
            ("black", SPLASH, 0.5),
            ("black", SESSION, 1.0),
            ("background", SESSION, 3.0),
            ("home", SESSION, 5.0),
        )
        self.assertEqual(status, 1)
        self.assertEqual(len(verdict["gaps"]), 2, verdict)
        self.assertEqual(verdict["session_black_seconds"], 0)


if __name__ == "__main__":
    unittest.main()
