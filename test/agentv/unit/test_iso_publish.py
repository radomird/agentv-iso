"""bin/agentv-iso-publish: three ISOs in the bucket under names that don't
change, and a clean-up that can only ever take out an old ISO's files.

A stand-in for the AWS CLI is first on PATH. It keeps a folder as the
bucket, writes down every call, and can be told to fail a listing."""

import hashlib
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PUBLISH = ROOT / "bin" / "agentv-iso-publish"

# The stand-in: FAKE_BUCKET is the bucket, FAKE_LOG every call it got.
AWS = r'''#!{python}
import json, os, shutil, sys
from pathlib import Path

args = sys.argv[1:]
bucket = Path(os.environ["FAKE_BUCKET"])
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")

def flag(name):
    return args[args.index(name) + 1]

command = " ".join(args[:2])
if command == "s3 cp":
    key = args[-1].split("/", 3)[3]
    (bucket / key).parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args[-2], bucket / key)
elif command == "s3api head-object":
    path = bucket / flag("--key")
    if not path.is_file():
        sys.exit(254)
    size = path.stat().st_size
    short = os.environ.get("FAKE_SHORT")
    if short and str(path).endswith(short):
        size -= 1
    print(size)
elif command == "s3api list-objects-v2":
    if os.environ.get("FAKE_LIST_FAILS"):
        sys.exit("An error occurred (InternalError)")
    if os.environ.get("FAKE_LIST_GARBAGE"):
        print("<html>busy</html>")
        sys.exit(0)
    prefix = "" if os.environ.get("FAKE_LIST_WHOLE_BUCKET") else flag("--prefix")
    keys = sorted(str(p.relative_to(bucket)) for p in bucket.rglob("*") if p.is_file())
    keys = [key for key in keys if key.startswith(prefix)]
    print(json.dumps(keys or None))
elif command == "s3api delete-object":
    path = bucket / flag("--key")
    if path.is_file():
        path.unlink()
else:
    sys.exit("the stand-in doesn't know: " + " ".join(args))
'''


class IsoPublish(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)
        self.bucket = self.work / "bucket"
        self.bucket.mkdir()
        self.log = self.work / "aws.log"
        self.log.write_text("")
        bin_dir = self.work / "bin"
        bin_dir.mkdir()
        aws = bin_dir / "aws"
        aws.write_text(AWS.replace("{python}", sys.executable))
        aws.chmod(aws.stat().st_mode | stat.S_IXUSR)
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_BUCKET": str(self.bucket),
            "FAKE_LOG": str(self.log),
            "R2_ACCOUNT_ID": "account",
            "R2_ACCESS_KEY_ID": "id",
            "R2_SECRET_ACCESS_KEY": "secret",
            "R2_BUCKET": "bucket",
            "ISO_URL": "https://downloads.example.invalid/",
        }
        for name in ("FAKE_SHORT", "FAKE_LIST_FAILS", "FAKE_LIST_GARBAGE", "FAKE_LIST_WHOLE_BUCKET", "AGENTV_ISO_STALE_MAX"):
            self.env.pop(name, None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_publish(self, *args, **env):
        return subprocess.run([str(PUBLISH), *args], env={**self.env, **env}, capture_output=True, text=True)

    def built(self, name, content=b"an ISO"):
        """An ISO and the checksum file a build leaves beside it."""
        folder = self.work / "release"
        folder.mkdir(exist_ok=True)
        iso = folder / f"{name}.iso"
        iso.write_bytes(content)
        (folder / f"{name}.iso.sha256").write_text(f"{hashlib.sha256(content).hexdigest()}  {name}.iso\n")
        return iso

    def publish(self, channel, name, content=b"an ISO", signed=True):
        iso = self.built(name, content)
        names = self.work / f"names-{channel}"
        result = self.run_publish("names", channel, f"{iso}.sha256", str(names))
        self.assertEqual(result.returncode, 0, result.stderr)
        if signed:
            (names / f"agentv-{channel}.iso.sha256.sig").write_bytes(b"a signature")
        result = self.run_publish("upload", channel, str(iso), str(names))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def put(self, key, content=b"x"):
        path = self.bucket / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def keys(self):
        return sorted(str(p.relative_to(self.bucket)) for p in self.bucket.rglob("*") if p.is_file())

    def calls(self, start):
        return [line for line in self.log.read_text().splitlines() if line.startswith(start)]

    def deleted(self):
        return [line.split("--key ")[1] for line in self.calls("s3api delete-object")]

    # --- names -------------------------------------------------------------

    def test_the_checksum_file_names_the_published_name(self):
        iso = self.built("agentv-1.0.0-x86_64", b"release")
        names = self.work / "names"
        result = self.run_publish("names", "stable", f"{iso}.sha256", str(names))
        self.assertEqual(result.returncode, 0, result.stderr)
        digest = hashlib.sha256(b"release").hexdigest()
        self.assertEqual((names / "agentv-stable.iso.sha256").read_text(), f"{digest}  agentv-stable.iso\n")
        self.assertEqual((names / "agentv-stable.version").read_text(), "1.0.0\n")
        # sha256sum -c passes on a download saved under the published name.
        (names / "agentv-stable.iso").write_bytes(b"release")
        check = subprocess.run(["sha256sum", "-c", "agentv-stable.iso.sha256"], cwd=names, capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)

    def test_each_channel_says_which_version_it_is(self):
        for channel, name, version in (
            ("rc", "agentv-1.0.0-rc1-x86_64", "1.0.0-rc1"),
            ("edge", "agentv-edge-2026.11.10-abc1234-x86_64", "edge-2026.11.10-abc1234"),
        ):
            iso = self.built(name)
            names = self.work / f"names-{channel}"
            self.assertEqual(self.run_publish("names", channel, f"{iso}.sha256", str(names)).returncode, 0)
            self.assertEqual((names / f"agentv-{channel}.version").read_text(), f"{version}\n")

    def test_names_refuses_another_channel_or_another_file(self):
        iso = self.built("agentv-1.0.0-x86_64")
        self.assertNotEqual(self.run_publish("names", "nightly", f"{iso}.sha256", str(self.work / "n")).returncode, 0)
        odd = self.work / "odd.sha256"
        odd.write_text(f"{'0' * 64}  ../../etc/passwd\n")
        self.assertNotEqual(self.run_publish("names", "stable", str(odd), str(self.work / "n")).returncode, 0)
        self.assertFalse((self.work / "n").exists())

    # --- upload ------------------------------------------------------------

    def test_upload_uses_the_fixed_names(self):
        result = self.publish("stable", "agentv-1.0.0-x86_64")
        self.assertEqual(
            self.keys(),
            ["iso/agentv-stable.iso", "iso/agentv-stable.iso.sha256", "iso/agentv-stable.iso.sha256.sig", "iso/agentv-stable.version"],
        )
        self.assertEqual(result.stdout.strip(), "https://downloads.example.invalid/iso/agentv-stable.iso")
        targets = [call.split()[-1] for call in self.calls("s3 cp")]
        self.assertEqual(len(targets), 4)
        for target in targets:
            self.assertRegex(target, r"^s3://bucket/iso/agentv-stable\.(iso|iso\.sha256|iso\.sha256\.sig|version)$")

    def test_publishing_again_replaces_the_one_before(self):
        self.publish("stable", "agentv-1.0.0-x86_64", b"one")
        self.publish("stable", "agentv-1.0.1-x86_64", b"two")
        self.assertEqual((self.bucket / "iso/agentv-stable.iso").read_bytes(), b"two")
        self.assertEqual((self.bucket / "iso/agentv-stable.version").read_text(), "1.0.1\n")
        self.assertEqual(len(self.keys()), 4)

    def test_without_a_signature_the_old_one_goes(self):
        self.publish("stable", "agentv-1.0.0-x86_64", b"one")
        self.publish("stable", "agentv-1.0.1-x86_64", b"two", signed=False)
        self.assertNotIn("iso/agentv-stable.iso.sha256.sig", self.keys())
        self.assertEqual(self.deleted(), ["iso/agentv-stable.iso.sha256.sig"])

    def test_upload_refuses_an_iso_that_isnt_the_checksums(self):
        iso = self.built("agentv-1.0.0-x86_64", b"one")
        names = self.work / "names"
        self.run_publish("names", "stable", f"{iso}.sha256", str(names))
        iso.write_bytes(b"something else")
        result = self.run_publish("upload", "stable", str(iso), str(names))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text(), "")

    def test_upload_fails_when_the_bucket_has_another_size(self):
        iso = self.built("agentv-1.0.0-x86_64")
        names = self.work / "names"
        self.run_publish("names", "stable", f"{iso}.sha256", str(names))
        result = self.run_publish("upload", "stable", str(iso), str(names), FAKE_SHORT="agentv-stable.iso")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected", result.stderr)

    # --- stale and clean ---------------------------------------------------

    def fill(self):
        """The three sets, old versioned ISOs, and things that must stay."""
        self.publish("stable", "agentv-1.0.0-x86_64", b"s")
        self.publish("rc", "agentv-1.0.0-rc2-x86_64", b"r")
        self.publish("edge", "agentv-edge-2026.11.10-abc1234-x86_64", b"e")
        self.log.write_text("")
        self.old = [
            "iso/agentv-0.1.3-x86_64.iso",
            "iso/agentv-0.1.3-x86_64.iso.sha256",
            "iso/agentv-0.1.4-x86_64.iso",
            "iso/agentv-0.1.4-x86_64.iso.sha256",
            "iso/agentv-0.1.4-x86_64.iso.sha256.sig",
            "iso/agentv-beta.version",
        ]
        self.others = [
            "iso/README.txt",
            "iso/notes.version.txt",
            "iso/old/agentv-0.1.0-x86_64.iso",
            "iso/agentv 0.1.2.iso",
            "iso/agentv-0.1.4-x86_64.iso.torrent",
            "backgrounds/agentv-0.1.4-x86_64.iso",
            "index.html",
            "isos/agentv-0.1.4-x86_64.iso",
        ]
        for key in self.old + self.others:
            self.put(key)
        self.sets = [
            f"iso/agentv-{channel}.{ext}"
            for channel in ("edge", "stable", "rc")
            for ext in ("iso", "iso.sha256", "iso.sha256.sig", "version")
        ]

    def test_the_dry_run_prints_exactly_what_would_go_and_removes_nothing(self):
        self.fill()
        before = self.keys()
        result = self.run_publish("stale")
        self.assertEqual(result.returncode, 0, result.stderr)
        printed = [line.strip() for line in result.stdout.splitlines()[1:]]
        self.assertEqual(printed, sorted(self.old))
        self.assertEqual(self.keys(), before)
        self.assertEqual(self.calls("s3api delete-object"), [])

    def test_clean_removes_the_old_ones_and_only_them(self):
        self.fill()
        result = self.run_publish("clean")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(self.deleted()), sorted(self.old))
        self.assertEqual(self.keys(), sorted(self.sets + self.others))

    def test_every_removal_is_one_exact_key_under_iso(self):
        self.fill()
        self.run_publish("clean")
        deletes = self.calls("s3api delete-object")
        self.assertEqual(len(deletes), len(self.old))
        for call in deletes:
            key = call.split("--key ")[1]
            self.assertRegex(key, r"^iso/[A-Za-z0-9._-]+\.(iso|iso\.sha256|iso\.sha256\.sig|version)$")
            self.assertNotIn("*", call)
        log = self.log.read_text()
        for word in ("--recursive", "s3 rm", "s3 rb", "s3 sync", "delete-objects", "--delete"):
            self.assertNotIn(word, log)

    def test_a_listing_of_the_whole_bucket_still_removes_only_under_iso(self):
        self.fill()
        self.run_publish("clean", FAKE_LIST_WHOLE_BUCKET="1")
        self.assertEqual(sorted(self.deleted()), sorted(self.old))
        self.assertIn("backgrounds/agentv-0.1.4-x86_64.iso", self.keys())
        self.assertIn("isos/agentv-0.1.4-x86_64.iso", self.keys())

    def test_the_three_sets_survive(self):
        self.fill()
        self.run_publish("clean")
        for key in self.sets:
            self.assertIn(key, self.keys())

    def test_a_failed_listing_removes_nothing(self):
        self.fill()
        before = self.keys()
        for flag in ("FAKE_LIST_FAILS", "FAKE_LIST_GARBAGE"):
            for command in ("stale", "clean"):
                result = self.run_publish(command, **{flag: "1"})
                self.assertNotEqual(result.returncode, 0, f"{command} with {flag}")
                self.assertIn("nothing is removed", result.stderr)
        self.assertEqual(self.keys(), before)
        self.assertEqual(self.calls("s3api delete-object"), [])

    def test_without_the_stable_iso_nothing_is_removed(self):
        # The bucket as it is before the first release goes up under its new
        # name: the latest release is still only there by its version.
        self.publish("edge", "agentv-edge-2026.11.10-abc1234-x86_64")
        for key in ("iso/agentv-0.1.4-x86_64.iso", "iso/agentv-0.1.4-x86_64.iso.sha256"):
            self.put(key)
        self.log.write_text("")
        before = self.keys()
        for command in ("stale", "clean"):
            result = self.run_publish(command)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("nothing is removed", result.stderr)
        self.assertEqual(self.keys(), before)
        self.assertEqual(self.calls("s3api delete-object"), [])

    def test_too_long_a_list_removes_nothing(self):
        self.fill()
        for number in range(30):
            self.put(f"iso/agentv-0.0.{number}-x86_64.iso")
        before = self.keys()
        for command in ("stale", "clean"):
            result = self.run_publish(command)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("more than 20", result.stderr)
        self.assertEqual(self.keys(), before)
        self.assertEqual(self.calls("s3api delete-object"), [])
        # The limit is the caller's to lower, too.
        self.assertNotEqual(self.run_publish("clean", AGENTV_ISO_STALE_MAX="3").returncode, 0)
        self.assertEqual(self.keys(), before)

    def test_nothing_to_remove_is_fine(self):
        self.publish("stable", "agentv-1.0.0-x86_64")
        self.log.write_text("")
        result = self.run_publish("clean")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("s3api delete-object"), [])


if __name__ == "__main__":
    unittest.main()
