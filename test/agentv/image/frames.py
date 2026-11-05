#!/usr/bin/env python3
#
# What the TV shows while the box starts, frame by frame (ADR-060, T2.1).
#
#   frames.py record --qmp <socket> --out <dir> [--serial <log>] [--stop <file>] [--max <seconds>]
#       Reads the VM's screen over a QMP socket of its own, about ten times a
#       second, and keeps every frame that differs from the one before it, in
#       <dir>, with when it came and how long it stayed in <dir>/index.json.
#       A VM started paused (-S) is let go once the first frame is in, so
#       nothing of the start is missed. With --serial, it also notes when the
#       firmware hands over to the boot loader ("BdsDxe: starting", which
#       OVMF writes there). It stops when the --stop file appears, or after
#       --max seconds.
#
#   frames.py analyse --out <dir> --background <#rrggbb> --home <regex>
#       Reads every kept frame after the firmware's and says what it is:
#       AgenTV's splash (the splash's background with the logo's colours on
#       it), the splash's background alone, black, Limine's menu, text, or
#       home (OCR finds the regex). It prints the timeline, writes it to
#       <dir>/timeline.json with a verdict for each rule, and keeps one frame
#       of each stretch as a PNG, deleting the rest.
#
# It needs python3, magick and tesseract, as the image checks' container has.

import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

# AgenTV's logo, as branding/plymouth-logo.png draws it: "agen" and "tv".
LOGO_COLOURS = ("#C0CAF5", "#7AA2F7")
# What Limine's menu says when it shows (its help line and its entries).
MENU_WORDS = re.compile(r"\b(limine|snapshots?|booting automatically|arrows|edit|firmware setup)\b", re.I)
# A word, for the text rule: three letters or more. OCR reads a picture's
# edges as one or two letters at times, never as a word.
WORD = re.compile(r"[A-Za-z]{3,}")


class Qmp:
    def __init__(self, path, wait=15):
        deadline = time.time() + wait
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except OSError:
                self.sock.close()
                if time.time() > deadline:
                    raise
                time.sleep(0.05)
        self.buf = b""
        self.read()  # the greeting
        self.call("qmp_capabilities")

    def read(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("QEMU closed the QMP socket")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, command, **arguments):
        message = {"execute": command}
        if arguments:
            message["arguments"] = arguments
        self.sock.sendall(json.dumps(message).encode() + b"\n")
        while True:
            reply = self.read()
            if "return" in reply or "error" in reply:
                return reply


def record(args):
    os.makedirs(args.out, exist_ok=True)
    qmp = Qmp(args.qmp)
    started = time.time()
    status = qmp.call("query-status").get("return", {})
    paused = status.get("status") == "prelaunch" or status.get("running") is False
    shot = os.path.join(args.out, ".shot")
    # PNG straight from QEMU where it can, otherwise its default PPM.
    form = "png"
    frames, events = [], []
    last = None
    serial_seen = 0
    handed_over = False

    while True:
        now = time.time()
        if os.path.exists(args.stop) or now - started > args.max:
            break
        reply = qmp.call("screendump", filename=shot, format=form) if form == "png" else qmp.call("screendump", filename=shot)
        if "error" in reply and form == "png":
            form = "ppm"
            continue
        try:
            with open(shot, "rb") as f:
                data = f.read()
        except OSError:
            data = b""
        if data:
            digest = hashlib.md5(data).hexdigest()
            if digest != last:
                name = f"frame-{len(frames) + 1:04d}.{form}"
                os.replace(shot, os.path.join(args.out, name))
                frames.append({"file": name, "t": round(now - started, 3), "until": round(now - started, 3)})
                last = digest
            else:
                frames[-1]["until"] = round(now - started, 3)
        if paused:
            # The first frame is in: the VM can start now.
            qmp.call("cont")
            paused = False
            events.append({"event": "started", "t": round(time.time() - started, 3)})
        if args.serial and not handed_over:
            try:
                with open(args.serial, "rb") as f:
                    f.seek(serial_seen)
                    text = f.read()
                if b"BdsDxe: starting" in text:
                    handed_over = True
                    events.append({"event": "boot loader", "t": round(time.time() - started, 3)})
                else:
                    serial_seen = max(0, serial_seen + len(text) - 64)
            except OSError:
                pass
        # About ten a second, however long the dump took.
        time.sleep(max(0.0, 0.1 - (time.time() - now)))

    with open(os.path.join(args.out, "index.json"), "w") as f:
        json.dump({"frames": frames, "events": events, "format": form, "seconds": round(time.time() - started, 3)}, f, indent=1)
    print(f"frames.py: {len(frames)} different frames in {time.time() - started:.1f} s")


def run(command):
    return subprocess.run(command, capture_output=True, text=True).stdout


def rgb(hex_colour):
    hex_colour = hex_colour.lstrip("#")
    return tuple(int(hex_colour[i : i + 2], 16) for i in (0, 2, 4))


def near(a, b, tolerance=12):
    return all(abs(x - y) <= tolerance for x, y in zip(a, b))


# The colours a frame is made of: how much of it is each one.
def histogram(path):
    counts = {}
    total = 0
    for line in run(["magick", path, "-format", "%c", "histogram:info:-"]).splitlines():
        found = re.match(r"\s*(\d+):.*?(#[0-9A-Fa-f]{6})", line)
        if found:
            count = int(found.group(1))
            counts[found.group(2).upper()] = counts.get(found.group(2).upper(), 0) + count
            total += count
    return counts, total


# What OCR reads. With mask, the logo's own box is painted over in the
# background colour first, so the logo itself never reads as text.
def ocr(path, work, background=None):
    prepared = os.path.join(work, ".ocr.png")
    command = ["magick", path]
    if background:
        box = run(
            [
                "magick", path, "-fuzz", "3%", "-fill", "white",
                "-opaque", LOGO_COLOURS[0], "-opaque", LOGO_COLOURS[1],
                "-fill", "black", "+opaque", "white", "-format", "%@", "info:",
            ]
        ).strip()
        found = re.match(r"(\d+)x(\d+)\+(\d+)\+(\d+)", box)
        if found:
            w, h, x, y = map(int, found.groups())
            if w > 1 and h > 1:
                command += ["-fill", background, "-draw", f"rectangle {x - 8},{y - 8} {x + w + 8},{y + h + 8}"]
    command += ["-colorspace", "gray", "-negate", "-resize", "150%", prepared]
    subprocess.run(command, capture_output=True)
    return run(["tesseract", prepared, "-", "--psm", "11"])


# What one frame is.
def classify(path, work, background, home):
    text = ocr(path, work)
    if home.search(text):
        return "home", ""
    if MENU_WORDS.search(text):
        return "menu", " ".join(WORD.findall(text))
    counts, total = histogram(path)
    total = total or 1
    black = sum(n for colour, n in counts.items() if max(rgb(colour)) <= 16) / total
    ground = sum(n for colour, n in counts.items() if near(rgb(colour), rgb(background))) / total
    logo = sum(counts.get(colour, 0) for colour in LOGO_COLOURS)
    splash = ground >= 0.6 and logo >= 1000
    if splash:
        # Read again without the logo: anything left is text.
        text = ocr(path, work, background)
    words = " ".join(WORD.findall(text))
    if words:
        return "text", words
    if black >= 0.9:
        return "black", ""
    if splash:
        return "splash", ""
    if ground >= 0.9:
        return "background", ""
    return "other", ""


def analyse(args):
    with open(os.path.join(args.out, "index.json")) as f:
        index = json.load(f)
    frames = index["frames"]
    events = {e["event"]: e["t"] for e in index.get("events", [])}
    handover = events.get("boot loader")
    home = re.compile(args.home, re.I)

    # The firmware's own screen is the firmware's until it changes, after the
    # hand-over too: Limine draws nothing in its quiet second, so what was
    # there stays there. Frames are kept only when they change, so that's
    # the last frame that came before the hand-over.
    firmware_until = -1
    if handover is not None:
        for i, frame in enumerate(frames):
            if frame["t"] <= handover:
                firmware_until = i

    timeline = []
    for i, frame in enumerate(frames):
        path = os.path.join(args.out, frame["file"])
        kind, words = ("firmware", "") if i <= firmware_until else classify(path, args.out, args.background, home)
        timeline.append({"file": frame["file"], "t": frame["t"], "until": frame["until"], "kind": kind, "words": words})

    # The rules, from the hand-over on, until home.
    after = timeline[firmware_until + 1 :]
    first_splash = next((i for i, f in enumerate(after) if f["kind"] == "splash"), None)
    first_home = next((i for i, f in enumerate(after) if f["kind"] == "home"), None)
    end = first_home if first_home is not None else len(after)
    # Home's page being drawn: the last moment before its words are all
    # there, when a frame can be anything of home's.
    drawing = (after[first_home]["t"] - 1.5) if first_home is not None else None

    def before(frame):
        return drawing is None or frame["until"] < drawing

    on_the_way = after[:end]
    since_splash = after[first_splash:end] if first_splash is not None else []
    seconds = lambda f: f["until"] - f["t"] + 0.1  # noqa: E731
    verdict = {
        "handover": handover is not None,
        "splash": first_splash is not None,
        "home": first_home is not None,
        "menu": [f"{f['file']}: {f['words']}" for f in on_the_way if f["kind"] == "menu"],
        "text": [f"{f['file']}: {f['words']}" for f in on_the_way if f["kind"] == "text" and before(f)],
        "gaps": [f"{f['file']} ({f['kind']}, {seconds(f):.1f} s)" for f in since_splash if f["kind"] == "black" or (f["kind"] == "other" and before(f))],
        "background_seconds": round(sum(seconds(f) for f in since_splash if f["kind"] == "background"), 1),
        "boot_loader_at": handover,
        "splash_at": after[first_splash]["t"] if first_splash is not None else None,
        "home_at": after[first_home]["t"] if first_home is not None else None,
    }
    failed = not (verdict["handover"] and verdict["splash"] and verdict["home"]) or verdict["menu"] or verdict["text"] or verdict["gaps"]

    # One frame of each stretch is kept, as a PNG, and the rest go. When a
    # rule failed, every frame that isn't the firmware's or the splash stays.
    previous = None
    for entry in timeline:
        path = os.path.join(args.out, entry["file"])
        keep = entry["kind"] != previous or (failed and entry["kind"] not in ("firmware", "splash"))
        previous = entry["kind"]
        if keep and not path.endswith(".png"):
            png = path.rsplit(".", 1)[0] + ".png"
            subprocess.run(["magick", path, png], capture_output=True)
            os.remove(path)
            entry["file"] = os.path.basename(png)
        elif not keep:
            os.remove(path)
            entry["file"] = None

    # The timeline, a line for each stretch.
    print(f"{'from':>8}  {'to':>8}  what")
    i = 0
    while i < len(timeline):
        entry, j = timeline[i], i
        while j + 1 < len(timeline) and timeline[j + 1]["kind"] == entry["kind"] and not entry["words"] and not timeline[j + 1]["words"]:
            j += 1
        said = f": {entry['words'][:80]}" if entry["words"] else ""
        shown = f" ({entry['file']})" if entry["file"] else ""
        count = f", {j - i + 1} frames" if j > i else ""
        print(f"{entry['t']:7.1f}s  {timeline[j]['until']:7.1f}s  {entry['kind']}{count}{said}{shown}")
        i = j + 1
    print(f"the firmware handed over to the boot loader at {handover:.1f} s" if handover is not None else "the firmware's hand-over wasn't seen")

    with open(os.path.join(args.out, "timeline.json"), "w") as f:
        json.dump({"verdict": verdict, "timeline": timeline}, f, indent=1)
    try:
        os.remove(os.path.join(args.out, ".ocr.png"))
    except OSError:
        pass
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description="What the TV shows while the box starts, frame by frame")
    sub = parser.add_subparsers(dest="command", required=True)
    rec = sub.add_parser("record")
    rec.add_argument("--qmp", required=True)
    rec.add_argument("--out", required=True)
    rec.add_argument("--serial")
    rec.add_argument("--stop", required=True)
    rec.add_argument("--max", type=float, default=600)
    ana = sub.add_parser("analyse")
    ana.add_argument("--out", required=True)
    ana.add_argument("--background", required=True)
    ana.add_argument("--home", required=True)
    args = parser.parse_args()
    if args.command == "record":
        return record(args)
    return analyse(args)


if __name__ == "__main__":
    sys.exit(main())
