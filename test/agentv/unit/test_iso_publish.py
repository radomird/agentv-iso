"""bin/agentv-iso-publish: one ISO for each channel in the bucket, named by
its version, a small file per channel that says which ISO that is, and a
clean-up that can only ever take out the ISO a channel had before.

A stand-in for the AWS CLI is first on PATH. It keeps a folder as the
bucket, writes down every call, and can be told to fail an upload or to
give a listing that's failed, garbled, cut short or missing a key."""

import hashlib
import json
import os
import shutil
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
    fails = os.environ.get("FAKE_CP_FAILS")
    if fails and key.endswith(fails):
        sys.exit("upload failed")
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
    truncated = False
    # A page that stops early and says so.
    if os.environ.get("FAKE_LIST_TRUNCATED"):
        keys, truncated = keys[: int(os.environ["FAKE_LIST_TRUNCATED"])], True
    count = len(keys)
    # A listing that leaves keys out and doesn't say so.
    hides = os.environ.get("FAKE_LIST_HIDES")
    if hides:
        keys = [key for key in keys if not key.endswith(hides)]
        if not os.environ.get("FAKE_LIST_KEEPS_COUNT"):
            count = len(keys)
    print(json.dumps({"keys": keys or None, "truncated": truncated, "count": count}))
elif command == "s3api get-object":
    if os.environ.get("FAKE_GET_FAILS"):
        sys.exit("An error occurred (InternalError)")
    path = bucket / flag("--key")
    if not path.is_file():
        sys.exit("An error occurred (NoSuchKey)")
    shutil.copyfile(path, args[-1])
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
        for name in (
            "FAKE_SHORT", "FAKE_CP_FAILS", "FAKE_GET_FAILS", "FAKE_LIST_FAILS", "FAKE_LIST_GARBAGE", "FAKE_LIST_WHOLE_BUCKET",
            "FAKE_LIST_TRUNCATED", "FAKE_LIST_HIDES", "FAKE_LIST_KEEPS_COUNT", "AGENTV_ISO_STALE_MAX",
        ):
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

    def named(self, channel, name, content=b"an ISO", signed=True):
        """What the jobs before the upload leave: the ISO and its names folder."""
        iso = self.built(name, content)
        names = self.work / f"names-{name}"
        result = self.run_publish("names", channel, f"{iso}.sha256", str(names))
        self.assertEqual(result.returncode, 0, result.stderr)
        if signed:
            (names / f"{name}.iso.sha256.sig").write_bytes(b"a signature")
        return iso, names

    def publish(self, channel, name, content=b"an ISO", signed=True):
        iso, names = self.named(channel, name, content, signed)
        result = self.run_publish("upload", channel, str(iso), str(names))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def pointer(self, channel):
        return json.loads((self.bucket / f"iso/{channel}.json").read_text())

    def files(self, name, signed=True):
        return [f"iso/{name}.iso", f"iso/{name}.iso.sha256"] + ([f"iso/{name}.iso.sha256.sig"] if signed else [])

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

    def test_the_checksum_file_names_the_versioned_iso(self):
        iso = self.built("agentv-1.0.0-x86_64", b"release")
        names = self.work / "names"
        result = self.run_publish("names", "stable", f"{iso}.sha256", str(names))
        self.assertEqual(result.returncode, 0, result.stderr)
        digest = hashlib.sha256(b"release").hexdigest()
        self.assertEqual([path.name for path in names.iterdir()], ["agentv-1.0.0-x86_64.iso.sha256"])
        self.assertEqual((names / "agentv-1.0.0-x86_64.iso.sha256").read_text(), f"{digest}  agentv-1.0.0-x86_64.iso\n")
        # sha256sum -c passes on a download, and prints its versioned name.
        (names / "agentv-1.0.0-x86_64.iso").write_bytes(b"release")
        check = subprocess.run(["sha256sum", "-c", "agentv-1.0.0-x86_64.iso.sha256"], cwd=names, capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        self.assertEqual(check.stdout.strip(), "agentv-1.0.0-x86_64.iso: OK")

    def test_a_version_belongs_to_one_channel(self):
        versions = {
            "stable": ["1.0.0"],
            "rc": ["1.0.0-rc1"],
            # What "agentv version" prints on an edge box, or the day and commit.
            "edge": ["0.2.0.r422.g155320d30", "edge-2026.11.10-abc1234"],
        }
        for channel in versions:
            for owner, theirs in versions.items():
                for version in theirs:
                    iso = self.built(f"agentv-{version}-x86_64")
                    names = self.work / f"names-{channel}-{version}"
                    result = self.run_publish("names", channel, f"{iso}.sha256", str(names))
                    if owner == channel:
                        self.assertEqual(result.returncode, 0, f"{version} as {channel}: {result.stderr}")
                        self.assertTrue((names / f"agentv-{version}-x86_64.iso.sha256").is_file())
                    else:
                        self.assertNotEqual(result.returncode, 0, f"{version} as {channel}")
                        self.assertFalse(names.exists())

    def test_names_refuses_another_channel_or_another_file(self):
        iso = self.built("agentv-1.0.0-x86_64")
        self.assertNotEqual(self.run_publish("names", "nightly", f"{iso}.sha256", str(self.work / "n")).returncode, 0)
        odd = self.work / "odd.sha256"
        odd.write_text(f"{'0' * 64}  ../../etc/passwd\n")
        self.assertNotEqual(self.run_publish("names", "stable", str(odd), str(self.work / "n")).returncode, 0)
        self.assertFalse((self.work / "n").exists())

    # --- upload ------------------------------------------------------------

    def test_upload_names_the_files_by_version(self):
        result = self.publish("stable", "agentv-1.0.0-x86_64")
        self.assertEqual(self.keys(), sorted(self.files("agentv-1.0.0-x86_64") + ["iso/stable.json"]))
        self.assertEqual(result.stdout.strip(), "https://downloads.example.invalid/iso/agentv-1.0.0-x86_64.iso")
        self.assertEqual(
            (self.bucket / "iso/agentv-1.0.0-x86_64.iso.sha256").read_text(),
            f"{hashlib.sha256(b'an ISO').hexdigest()}  agentv-1.0.0-x86_64.iso\n",
        )

    def test_each_channels_iso_carries_its_version(self):
        self.publish("rc", "agentv-1.0.0-rc1-x86_64")
        self.publish("edge", "agentv-0.2.0.r422.g155320d30-x86_64")
        self.assertIn("iso/agentv-1.0.0-rc1-x86_64.iso", self.keys())
        self.assertIn("iso/agentv-0.2.0.r422.g155320d30-x86_64.iso", self.keys())
        self.assertEqual(self.pointer("rc")["version"], "1.0.0-rc1")
        self.assertEqual(self.pointer("edge")["version"], "0.2.0.r422.g155320d30")
        for key in self.keys():
            for old in ("agentv-stable", "agentv-rc", "agentv-edge."):
                self.assertNotIn(old, key)

    def test_the_channels_file_says_which_iso_it_is(self):
        self.publish("stable", "agentv-1.0.0-x86_64", b"release")
        self.assertEqual(
            self.pointer("stable"),
            {
                "channel": "stable",
                "version": "1.0.0",
                "file": "agentv-1.0.0-x86_64.iso",
                "sha256": hashlib.sha256(b"release").hexdigest(),
                "url": "https://downloads.example.invalid/iso/agentv-1.0.0-x86_64.iso",
            },
        )

    def test_the_channels_file_goes_up_last_after_the_sizes_are_checked(self):
        self.publish("stable", "agentv-1.0.0-x86_64")
        calls = [line for line in self.log.read_text().splitlines() if line.startswith(("s3 cp", "s3api head-object"))]
        at = next(i for i, call in enumerate(calls) if call.startswith("s3 cp") and call.endswith("/iso/stable.json"))
        before = calls[:at]
        for key in self.files("agentv-1.0.0-x86_64"):
            self.assertTrue(any(call.startswith("s3 cp") and call.endswith(f"/{key}") for call in before), key)
            self.assertTrue(any(call.startswith("s3api head-object") and f"--key {key} " in call for call in before), key)
        self.assertFalse(any(call.startswith("s3 cp") for call in calls[at + 1:]))

    def test_a_failed_upload_leaves_the_channels_file_where_it_was(self):
        self.publish("stable", "agentv-1.0.0-x86_64", b"one")
        before = (self.bucket / "iso/stable.json").read_bytes()
        iso, names = self.named("stable", "agentv-1.0.1-x86_64", b"two")
        for part in (".iso", ".iso.sha256", ".iso.sha256.sig"):
            result = self.run_publish("upload", "stable", str(iso), str(names), FAKE_CP_FAILS=f"agentv-1.0.1-x86_64{part}")
            self.assertNotEqual(result.returncode, 0, part)
            self.assertEqual((self.bucket / "iso/stable.json").read_bytes(), before, part)
        # And the ISO before is still there to download.
        for key in self.files("agentv-1.0.0-x86_64"):
            self.assertIn(key, self.keys())

    def test_a_failed_size_check_leaves_the_channels_file_where_it_was(self):
        self.publish("stable", "agentv-1.0.0-x86_64", b"one")
        before = (self.bucket / "iso/stable.json").read_bytes()
        iso, names = self.named("stable", "agentv-1.0.1-x86_64", b"two")
        for part in (".iso", ".iso.sha256", ".iso.sha256.sig"):
            result = self.run_publish("upload", "stable", str(iso), str(names), FAKE_SHORT=f"agentv-1.0.1-x86_64{part}")
            self.assertNotEqual(result.returncode, 0, part)
            self.assertIn("expected", result.stderr)
            self.assertEqual((self.bucket / "iso/stable.json").read_bytes(), before, part)

    def test_a_first_publish_that_fails_writes_no_channels_file(self):
        iso, names = self.named("stable", "agentv-1.0.0-x86_64")
        result = self.run_publish("upload", "stable", str(iso), str(names), FAKE_SHORT="agentv-1.0.0-x86_64.iso")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("iso/stable.json", self.keys())
        self.assertEqual([call for call in self.calls("s3 cp") if call.endswith(".json")], [])

    def test_a_different_iso_under_the_live_name_is_refused(self):
        self.publish("stable", "agentv-1.0.0-x86_64", b"one")
        before = {key: (self.bucket / key).read_bytes() for key in self.keys()}
        self.log.write_text("")
        iso, names = self.named("stable", "agentv-1.0.0-x86_64", b"two")
        result = self.run_publish("upload", "stable", str(iso), str(names))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("isn't replaced under the same name", result.stderr)
        self.assertEqual(result.stdout, "")
        # Nothing went up and nothing went away.
        self.assertEqual({key: (self.bucket / key).read_bytes() for key in self.keys()}, before)
        self.assertEqual(self.calls("s3 cp"), [])
        self.assertEqual(self.deleted(), [])

    def test_the_same_iso_again_keeps_the_live_bytes(self):
        self.publish("stable", "agentv-1.0.0-x86_64", b"one", signed=False)
        self.assertNotIn("iso/agentv-1.0.0-x86_64.iso.sha256.sig", self.keys())
        before = (self.bucket / "iso/stable.json").read_bytes()
        self.log.write_text("")
        # Again, now that there's a signature to go with it.
        result = self.publish("stable", "agentv-1.0.0-x86_64", b"one")
        self.assertEqual(result.stdout.strip(), "https://downloads.example.invalid/iso/agentv-1.0.0-x86_64.iso")
        self.assertEqual([call for call in self.calls("s3 cp") if call.endswith("/iso/agentv-1.0.0-x86_64.iso")], [])
        self.assertEqual(self.deleted(), [])
        self.assertEqual(self.keys(), sorted(self.files("agentv-1.0.0-x86_64") + ["iso/stable.json"]))
        self.assertEqual((self.bucket / "iso/stable.json").read_bytes(), before)
        # Its size is still asked for, so a live ISO that's gone short stops it.
        self.assertTrue(any("--key iso/agentv-1.0.0-x86_64.iso " in call for call in self.calls("s3api head-object")))
        iso, names = self.named("stable", "agentv-1.0.0-x86_64", b"one")
        result = self.run_publish("upload", "stable", str(iso), str(names), FAKE_SHORT="agentv-1.0.0-x86_64.iso")
        self.assertNotEqual(result.returncode, 0)

    def test_the_same_iso_again_without_a_signature_keeps_the_one_it_has(self):
        self.publish("stable", "agentv-1.0.0-x86_64", b"one")
        self.publish("stable", "agentv-1.0.0-x86_64", b"one", signed=False)
        self.assertIn("iso/agentv-1.0.0-x86_64.iso.sha256.sig", self.keys())
        self.assertEqual(self.deleted(), [])

    def test_a_name_that_isnt_live_can_be_uploaded_again(self):
        # A publish that stopped before the channel's file moved left an ISO
        # nobody is pointed at. The next try replaces it.
        self.publish("stable", "agentv-1.0.0-x86_64", b"one")
        iso, names = self.named("stable", "agentv-1.0.1-x86_64", b"two")
        result = self.run_publish("upload", "stable", str(iso), str(names), FAKE_CP_FAILS="agentv-1.0.1-x86_64.iso.sha256")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.bucket / "iso/agentv-1.0.1-x86_64.iso").read_bytes(), b"two")
        self.publish("stable", "agentv-1.0.1-x86_64", b"three")
        self.assertEqual((self.bucket / "iso/agentv-1.0.1-x86_64.iso").read_bytes(), b"three")
        self.assertEqual(self.pointer("stable")["sha256"], hashlib.sha256(b"three").hexdigest())

    def test_without_a_signature_one_left_under_that_name_goes(self):
        # Left by a publish that never became the channel's ISO.
        self.put("iso/agentv-1.0.0-x86_64.iso.sha256.sig", b"an older signature")
        self.publish("stable", "agentv-1.0.0-x86_64", b"two", signed=False)
        self.assertNotIn("iso/agentv-1.0.0-x86_64.iso.sha256.sig", self.keys())
        self.assertEqual(self.deleted(), ["iso/agentv-1.0.0-x86_64.iso.sha256.sig"])

    def test_a_channels_file_that_cant_be_read_stops_the_upload(self):
        self.publish("stable", "agentv-1.0.0-x86_64", b"one")
        self.log.write_text("")
        iso, names = self.named("stable", "agentv-1.0.0-x86_64", b"two")
        result = self.run_publish("upload", "stable", str(iso), str(names), FAKE_GET_FAILS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("couldn't read the bucket's iso/stable.json", result.stderr)
        self.assertEqual(self.calls("s3 cp"), [])
        self.assertEqual((self.bucket / "iso/agentv-1.0.0-x86_64.iso").read_bytes(), b"one")

    def test_upload_refuses_an_iso_that_isnt_the_checksums(self):
        iso, names = self.named("stable", "agentv-1.0.0-x86_64", b"one")
        iso.write_bytes(b"something else")
        result = self.run_publish("upload", "stable", str(iso), str(names))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text(), "")

    def test_upload_refuses_another_channels_iso(self):
        iso, names = self.named("rc", "agentv-1.0.0-rc1-x86_64")
        result = self.run_publish("upload", "stable", str(iso), str(names))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text(), "")

    # --- stale and clean ---------------------------------------------------

    def fill(self):
        """Each channel on its second ISO, with its first still there, the
        files from when they went by the channel's name, and things that
        must stay."""
        self.publish("stable", "agentv-1.0.0-x86_64", b"s1")
        self.publish("stable", "agentv-1.0.1-x86_64", b"s2")
        self.publish("rc", "agentv-1.1.0-rc1-x86_64", b"r1")
        self.publish("rc", "agentv-1.1.0-rc2-x86_64", b"r2")
        self.publish("edge", "agentv-edge-2026.11.10-abc1234-x86_64", b"e1")
        self.publish("edge", "agentv-1.0.1.r3.g155320d30-x86_64", b"e2")
        self.log.write_text("")
        self.now = {
            "stable": self.files("agentv-1.0.1-x86_64") + ["iso/stable.json"],
            "rc": self.files("agentv-1.1.0-rc2-x86_64") + ["iso/rc.json"],
            "edge": self.files("agentv-1.0.1.r3.g155320d30-x86_64") + ["iso/edge.json"],
        }
        self.before = {
            "stable": self.files("agentv-1.0.0-x86_64") + self.files("agentv-0.1.4-x86_64", signed=False),
            "rc": self.files("agentv-1.1.0-rc1-x86_64"),
            "edge": self.files("agentv-edge-2026.11.10-abc1234-x86_64"),
        }
        for channel in self.before:
            self.before[channel] += self.files(f"agentv-{channel}") + [f"iso/agentv-{channel}.version"]
        self.others = [
            "iso/README.txt",
            "iso/notes.version.txt",
            "iso/beta.json",
            "iso/agentv-beta.version",
            "iso/agentv-beta.iso",
            "iso/omarchy-4.5.0-x86_64.iso",
            "iso/agentv-1.0.0-aarch64.iso",
            "iso/old/agentv-0.1.0-x86_64.iso",
            "iso/agentv 0.1.2.iso",
            "iso/agentv-0.1.4-x86_64.iso.torrent",
            "backgrounds/agentv-0.1.4-x86_64.iso",
            "index.html",
            "isos/agentv-0.1.4-x86_64.iso",
        ]
        for keys in (*self.before.values(), self.others):
            for key in keys:
                self.put(key)

    def everything_but(self, channel):
        kept = [key for keys in self.now.values() for key in keys] + self.others
        kept += [key for other, keys in self.before.items() if other != channel for key in keys]
        return sorted(kept)

    def test_the_dry_run_prints_exactly_what_would_go_and_removes_nothing(self):
        self.fill()
        before = self.keys()
        result = self.run_publish("stale", "stable")
        self.assertEqual(result.returncode, 0, result.stderr)
        printed = [line.strip() for line in result.stdout.splitlines()[1:]]
        self.assertEqual(printed, sorted(self.before["stable"]))
        self.assertEqual(self.keys(), before)
        self.assertEqual(self.calls("s3api delete-object"), [])

    def test_clean_removes_the_iso_a_channel_had_before_and_only_that(self):
        for channel in ("stable", "rc", "edge"):
            self.fill()
            result = self.run_publish("clean", channel)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(sorted(self.deleted()), sorted(self.before[channel]), channel)
            # Its own ISO, the other channels' old and new, and the rest stay.
            self.assertEqual(self.keys(), self.everything_but(channel), channel)
            shutil.rmtree(self.bucket)
            self.bucket.mkdir()

    def test_every_removal_is_one_exact_key_under_iso(self):
        self.fill()
        self.run_publish("clean", "stable")
        deletes = self.calls("s3api delete-object")
        self.assertEqual(len(deletes), len(self.before["stable"]))
        for call in deletes:
            key = call.split("--key ")[1]
            self.assertRegex(key, r"^iso/[A-Za-z0-9._-]+\.(iso|iso\.sha256|iso\.sha256\.sig|version)$")
            self.assertNotIn("*", call)
        log = self.log.read_text()
        for word in ("--recursive", "s3 rm", "s3 rb", "s3 sync", "delete-objects", "--delete"):
            self.assertNotIn(word, log)

    def test_a_listing_of_the_whole_bucket_still_removes_only_under_iso(self):
        self.fill()
        self.run_publish("clean", "stable", FAKE_LIST_WHOLE_BUCKET="1")
        self.assertEqual(sorted(self.deleted()), sorted(self.before["stable"]))
        self.assertIn("backgrounds/agentv-0.1.4-x86_64.iso", self.keys())
        self.assertIn("isos/agentv-0.1.4-x86_64.iso", self.keys())

    def refused(self, why, *channels, **env):
        """stale and clean both stop, say why, and remove nothing."""
        before = self.keys()
        for channel in channels or ("stable", "rc", "edge"):
            for command in ("stale", "clean"):
                result = self.run_publish(command, channel, **env)
                self.assertNotEqual(result.returncode, 0, f"{command} {channel} {env}")
                self.assertIn(why, result.stderr)
        self.assertEqual(self.keys(), before)
        self.assertEqual(self.calls("s3api delete-object"), [])

    def test_a_failed_listing_removes_nothing(self):
        self.fill()
        self.refused("nothing is removed", FAKE_LIST_FAILS="1")
        self.refused("nothing is removed", FAKE_LIST_GARBAGE="1")

    def test_a_listing_cut_short_removes_nothing(self):
        # The bucket says there's more than this page, wherever it stops.
        self.fill()
        for shown in (1, 3, len(self.keys()) - 1):
            self.refused("cut short", FAKE_LIST_TRUNCATED=str(shown))
        # Or it says how many keys it has, and shows fewer.
        self.refused("cut short", FAKE_LIST_HIDES="README.txt", FAKE_LIST_KEEPS_COUNT="1")

    def test_a_listing_without_what_is_known_to_be_there_removes_nothing(self):
        # Nothing says it's short, but the channel's own ISO isn't in it.
        self.fill()
        self.refused("isn't whole", "stable", FAKE_LIST_HIDES="agentv-1.0.1-x86_64.iso")
        self.refused("isn't whole", "stable", FAKE_LIST_HIDES="agentv-1.0.1-x86_64.iso.sha256")
        self.refused("isn't whole", "stable", FAKE_LIST_HIDES="stable.json")
        self.refused("isn't whole", "edge", FAKE_LIST_HIDES="edge.json")

    def test_a_channel_with_no_file_of_its_own_has_nothing_removed(self):
        # The bucket before a channel's first ISO goes up under its version:
        # its ISO is still only there by the channel's name.
        self.publish("edge", "agentv-0.2.0.r422.g155320d30-x86_64")
        for key in self.files("agentv-stable") + ["iso/agentv-stable.version", "iso/agentv-0.1.4-x86_64.iso"]:
            self.put(key)
        self.log.write_text("")
        self.refused("nothing is removed", "stable", "rc")

    def test_a_channels_file_that_names_something_else_removes_nothing(self):
        self.fill()
        for content in (
            "not json",
            "[]",
            json.dumps({"file": "agentv-1.1.0-rc2-x86_64.iso"}),
            json.dumps({"file": "../agentv-1.0.1-x86_64.iso"}),
            json.dumps({"file": "*"}),
        ):
            self.put("iso/stable.json", content.encode())
            self.refused("nothing is removed", "stable")

    def test_too_long_a_list_removes_nothing(self):
        self.fill()
        for number in range(30):
            self.put(f"iso/agentv-0.0.{number}-x86_64.iso")
        self.refused("more than 20", "stable")
        # The limit is the caller's to lower, too.
        self.refused("more than 3", "stable", AGENTV_ISO_STALE_MAX="3")

    def test_stale_and_clean_need_a_channel(self):
        self.fill()
        before = self.keys()
        for command in ("stale", "clean"):
            self.assertNotEqual(self.run_publish(command).returncode, 0)
            self.assertNotEqual(self.run_publish(command, "nightly").returncode, 0)
        self.assertEqual(self.keys(), before)
        self.assertEqual(self.calls("s3api delete-object"), [])

    def test_nothing_to_remove_is_fine(self):
        self.publish("stable", "agentv-1.0.0-x86_64")
        self.log.write_text("")
        result = self.run_publish("clean", "stable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("s3api delete-object"), [])


if __name__ == "__main__":
    unittest.main()
