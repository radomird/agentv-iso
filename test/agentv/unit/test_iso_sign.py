"""bin/agentv-iso-sign signs an ISO's checksum only with the key this repo
pins, and the workflows give the signing key and the bucket's keys only to
the jobs that need them. Throwaway keys stand in for AgenTV's."""

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SIGN = ROOT / "bin" / "agentv-iso-sign"
WORKFLOWS = ROOT / ".github" / "workflows"


def gpg(home, *args, **kwargs):
    return subprocess.run(["gpg", "--homedir", str(home), "--batch", "--quiet", *args], capture_output=True, check=True, **kwargs)


@unittest.skipUnless(shutil.which("gpg") and shutil.which("gpgv"), "needs gpg and gpgv")
class IsoSign(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)
        self.keys = {}
        for who in ("agentv", "other"):
            home = self.work / f"{who}-home"
            home.mkdir(mode=0o700)
            gpg(home, "--passphrase", "", "--quick-gen-key", f"{who} <{who}@agentv.invalid>", "ed25519", "sign", "never")
            listing = gpg(home, "--with-colons", "--list-keys").stdout.decode()
            self.keys[who] = {
                "secret": gpg(home, "--armor", "--export-secret-keys").stdout.decode(),
                "public": gpg(home, "--export").stdout,
                "fingerprint": re.search(r"^fpr:+([0-9A-F]{40}):", listing, re.M).group(1),
            }
        self.pinned = self.work / "key-fingerprint"
        self.pinned.write_text(self.keys["agentv"]["fingerprint"] + "\n")
        self.sum = self.work / "agentv-stable.iso.sha256"
        self.sum.write_text(f"{'a' * 64}  agentv-stable.iso\n")
        self.sig = Path(f"{self.sum}.sig")

    def tearDown(self):
        self.tmp.cleanup()

    def sign(self, key, path=None):
        env = {k: v for k, v in os.environ.items() if k != "AGENTV_SIGNING_KEY"}
        if path:
            env["PATH"] = f"{path}:{env['PATH']}"
        if key is not None:
            env["AGENTV_SIGNING_KEY"] = key
        return subprocess.run([str(SIGN), str(self.sum), str(self.pinned)], env=env, capture_output=True, text=True)

    def test_it_signs_with_the_pinned_key(self):
        result = self.sign(self.keys["agentv"]["secret"])
        self.assertEqual(result.returncode, 0, result.stderr)
        keyring = self.work / "agentv.gpg"
        keyring.write_bytes(self.keys["agentv"]["public"])
        check = subprocess.run(["gpgv", "--keyring", str(keyring), str(self.sig), str(self.sum)], capture_output=True)
        self.assertEqual(check.returncode, 0, check.stderr)
        # The two lines the README gives people: gpg --verify, then the name.
        home = self.work / "reader"
        home.mkdir(mode=0o700)
        gpg(home, "--import", input=self.keys["agentv"]["public"])
        verify = subprocess.run(["gpg", "--homedir", str(home), "--batch", "--verify", str(self.sig), str(self.sum)], capture_output=True, text=True)
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self.assertIn(self.keys["agentv"]["fingerprint"][-16:], verify.stderr.replace(" ", ""))

    def test_another_key_signs_nothing(self):
        result = self.sign(self.keys["other"]["secret"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("isn't the one this repo pins", result.stderr)
        self.assertFalse(self.sig.exists())

    def test_without_the_key_it_stops(self):
        for key in (None, ""):
            result = self.sign(key)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.sig.exists())

    def test_two_keys_in_the_secret_stop_it(self):
        result = self.sign(self.keys["agentv"]["secret"] + self.keys["other"]["secret"])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.sig.exists())

    def test_the_key_is_out_of_the_environment_before_anything_else_runs(self):
        # gpgv, but it writes down whether the key was still around.
        fake = self.work / "bin"
        fake.mkdir()
        seen = self.work / "seen"
        script = fake / "gpgv"
        script.write_text(f'#!/bin/bash\necho "${{AGENTV_SIGNING_KEY:+leaked}}" >>"{seen}"\nexec "{shutil.which("gpgv")}" "$@"\n')
        script.chmod(script.stat().st_mode | stat.S_IXUSR)
        result = self.sign(self.keys["agentv"]["secret"], path=fake)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(seen.read_text().strip(), "")
        self.assertTrue(seen.exists())

    def test_the_repo_pins_one_key(self):
        pinned = (ROOT / "configs/airootfs/usr/share/agentv-iso/key-fingerprint").read_text().strip()
        self.assertRegex(pinned, r"^[0-9A-F]{40}$")


def jobs(workflow):
    """Each job's text, by name, without its comments."""
    text = (WORKFLOWS / workflow).read_text()
    body = text[text.index("\njobs:\n") + len("\njobs:\n"):]
    found = {}
    name = None
    for line in body.splitlines():
        match = re.match(r"^  ([a-z][a-z0-9-]*):$", line)
        if match:
            name = match.group(1)
            found[name] = []
        elif name and not line.lstrip().startswith("#"):
            found[name].append(line)
    return {name: "\n".join(lines) for name, lines in found.items()}


class WhoGetsTheKeys(unittest.TestCase):
    def test_only_the_signing_job_is_given_the_signing_key(self):
        publish = jobs("publish-iso.yml")
        self.assertEqual([name for name, text in publish.items() if "secrets.AGENTV_SIGNING_KEY" in text], ["sign"])
        self.assertIn("environment: release", publish["sign"])
        # It signs, and fetches or runs nothing else.
        for word in ("curl ", "gh ", "aws ", "docker ", "pacman", "git fetch", "git clone", "secrets.R2_"):
            self.assertNotIn(word, publish["sign"])

    def test_only_the_publishing_job_is_given_the_buckets_keys(self):
        publish = jobs("publish-iso.yml")
        self.assertEqual([name for name, text in publish.items() if "secrets.R2_" in text], ["publish"])
        self.assertIn("environment: release", publish["publish"])
        for name in ("which", "sum"):
            self.assertNotIn("secrets.", publish[name])
            self.assertNotIn("environment:", publish[name])

    def test_the_morning_publishes_only_a_scheduled_nights_iso(self):
        # A nightly run started by hand can check with an agentv-iso branch
        # that isn't merged, so its ISO is never picked up on its own.
        which = jobs("publish-iso.yml")["which"]
        asked = re.findall(r"workflows/nightly\.yml/runs\?(\S+?)\"", which)
        self.assertEqual(len(asked), 1)
        self.assertIn("event=schedule", asked[0].split("&"))
        self.assertIn("branch=agentv", asked[0].split("&"))

    def test_the_workflow_that_builds_the_iso_has_no_keys(self):
        # It runs for pull requests and tags, on their own code.
        text = "\n".join(line for line in (WORKFLOWS / "iso.yml").read_text().splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("secrets.", text)
        self.assertNotIn("secrets: inherit", text)
        self.assertNotIn("environment:", text)
        self.assertNotIn("agentv-iso-publish", text)

    def test_the_dry_run_is_a_step_of_its_own_before_the_removal(self):
        publish = jobs("publish-iso.yml")["publish"]
        upload = publish.index("agentv-iso-publish upload")
        stale = publish.index("agentv-iso-publish stale")
        clean = publish.index("agentv-iso-publish clean")
        self.assertLess(upload, stale)
        self.assertLess(stale, clean)
        between = publish[stale:clean]
        self.assertIn("- name:", between)
        # A pipe to the summary mustn't hide a failed listing.
        lines = [line.strip() for line in publish.splitlines()]
        for command in ("stale", "clean"):
            at = next(i for i, line in enumerate(lines) if line.startswith(f"bin/agentv-iso-publish {command} |"))
            self.assertEqual(lines[at - 1], "set -o pipefail")

if __name__ == "__main__":
    unittest.main()
