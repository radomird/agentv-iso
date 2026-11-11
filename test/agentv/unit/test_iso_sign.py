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
        self.sum = self.work / "agentv-1.0.0-x86_64.iso.sha256"
        self.sum.write_text(f"{'a' * 64}  agentv-1.0.0-x86_64.iso\n")
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

    def test_the_morning_asks_whether_the_nights_leg_passed(self):
        # A night that failed or was cancelled can still have its ISO, when
        # the job that takes it back didn't run or didn't find it.
        which = jobs("publish-iso.yml")["which"]
        found = which.index("kept no edge ISO")
        asked = which.index("bin/agentv-iso-passed edge")
        published = which.index("iso/edge.json")
        self.assertLess(found, asked)
        self.assertLess(asked, published)
        self.assertIn("/jobs?filter=latest", which)

    def passed(self, *rows, leg="edge"):
        lines = "".join('{"name": "%s", "status": "%s", "conclusion": %s}\n' % (name, status, f'"{conclusion}"' if conclusion else "null") for name, status, conclusion in rows)
        return subprocess.run([str(ROOT / "bin" / "agentv-iso-passed"), leg], input=lines.encode(), capture_output=True, check=False)

    def test_a_leg_passed_only_when_every_job_of_it_did(self):
        edge = "Install and test edge / "
        box = (edge + "Get the box ready", "completed", "success")
        one_job = (edge + "Build the ISO, install it, boot it, check it", "completed", "skipped")
        part = (edge + "Check it, part 3 of 4", "completed", "success")
        last = (edge + "Which image checks passed", "completed", "success")
        other = ("Install and test stable / Build the ISO, install it, boot it, check it", "completed", "failure")
        # In parts, and as the one job. Another leg's failure isn't this one's.
        self.assertEqual(self.passed(box, one_job, part, last, other).returncode, 0)
        self.assertEqual(self.passed((edge + "Build the ISO, install it, boot it, check it", "completed", "success"), other).returncode, 0)
        # A failed check, with or without the last job having run.
        failed = (edge + "Check it, part 3 of 4", "completed", "failure")
        self.assertEqual(self.passed(box, failed, (edge + "Which image checks passed", "completed", "failure")).returncode, 1)
        self.assertEqual(self.passed(box, failed).returncode, 1)
        # Cancelled, still running, or stopped before its last job.
        self.assertEqual(self.passed(box, (edge + "Check it, part 3 of 4", "completed", "cancelled")).returncode, 1)
        self.assertEqual(self.passed(box, part, (edge + "Which image checks passed", "in_progress", "")).returncode, 1)
        self.assertEqual(self.passed(box, part).returncode, 1)
        self.assertEqual(self.passed(box, part, (edge + "Which image checks passed", "completed", "skipped")).returncode, 1)
        # No such leg, and an answer that isn't a list of jobs.
        self.assertEqual(self.passed(other).returncode, 1)
        self.assertEqual(self.passed().returncode, 1)
        wrong = subprocess.run([str(ROOT / "bin" / "agentv-iso-passed"), "edge"], input=b'{"message": "Not Found"}\n', capture_output=True, check=False)
        self.assertEqual(wrong.returncode, 1)

    def test_the_workflow_that_builds_the_iso_has_no_keys(self):
        # It runs for pull requests and tags, on their own code.
        text = "\n".join(line for line in (WORKFLOWS / "iso.yml").read_text().splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("secrets.", text)
        self.assertNotIn("secrets: inherit", text)
        self.assertNotIn("environment:", text)
        self.assertNotIn("agentv-iso-publish", text)

    def test_the_signing_job_signs_the_checksum_under_the_isos_own_name(self):
        publish = jobs("publish-iso.yml")
        self.assertIn('bin/agentv-iso-sign "names/$NAME.iso.sha256"', publish["sign"])
        self.assertIn("NAME: ${{ needs.which.outputs.name }}", publish["sign"])
        # Nothing goes by a channel's name any more.
        for text in publish.values():
            self.assertNotIn("agentv-$CHANNEL", text)

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
        # Only the channel just published is cleaned.
        for command in ("stale", "clean"):
            at = next(i for i, line in enumerate(lines) if line.startswith(f'bin/agentv-iso-publish {command} "$CHANNEL" |'))
            self.assertEqual(lines[at - 1], "set -o pipefail")

if __name__ == "__main__":
    unittest.main()
