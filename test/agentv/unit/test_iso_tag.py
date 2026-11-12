"""A release tag, from the push to the published ISO.

bin/agentv-iso-tag is the one place that says what a release tag is:
agentv-v1.0.0, agentv-v1.0.0-rc1 for a candidate, and v0.2.0 for a 0.x
release. agentv-os carries Omarchy's own v1.1.0 to v4.5.0 tags, so no other
v tag is AgenTV's, here either.

bin/agentv-iso-carries checks that the ISO built for a tag carries the
package its name promises. bin/agentv-iso-notes writes the release's notes.
The ISO workflow and the publish workflow are read, and the steps that
decide are run as they're written, with stand-ins around them. Nothing here
asks GitHub or builds anything."""

import hashlib
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BIN = ROOT / "bin"
WORKFLOWS = ROOT / ".github" / "workflows"


def run(*args, env=None, cwd=None, stdin=None):
    return subprocess.run([str(arg) for arg in args], env=env, cwd=cwd, input=stdin, capture_output=True, text=True)


def step(workflow, name):
    """A step's script, as the workflow has it."""
    lines = (WORKFLOWS / workflow).read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() in (f"- name: {name}", f"- name: \"{name}\""))
    script = []
    running = False
    for line in lines[start + 1:]:
        if re.match(r"^      - ", line):
            break
        if running:
            script.append(line[10:] if line.startswith("          ") else line.strip())
        elif line.strip() == "run: |":
            running = True
    return "\n".join(script) + "\n"


class TheTag(unittest.TestCase):
    def tag(self, tag):
        return run(BIN / "agentv-iso-tag", tag)

    def test_a_release_and_a_candidate(self):
        for tag, said in (
            ("agentv-v1.0.0", "stable 1.0.0"),
            ("agentv-v1.0.0-rc1", "rc 1.0.0-rc1"),
            ("agentv-v1.2.10-rc12", "rc 1.2.10-rc12"),
            ("agentv-v0.3.0", "stable 0.3.0"),
            ("agentv-v10.20.30", "stable 10.20.30"),
        ):
            result = self.tag(tag)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), said)

    def test_a_0x_release_keeps_its_v_tag(self):
        for tag, said in (("v0.2.0", "stable 0.2.0"), ("v0.1.4", "stable 0.1.4"), ("v0.10.0", "stable 0.10.0")):
            result = self.tag(tag)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), said)

    def test_no_other_tag_is_agentvs(self):
        # Omarchy's own, a v tag for 1.0 or later, an old-style candidate,
        # and names that only look the part.
        for tag in (
            "v1.1.0", "v4.5.0", "v1.0.0", "v4.5.0-rc1", "v1.0.0-rc1", "v0.3.0-rc1", "v0.2", "v0.2.0.1", "v0.2.0x",
            "agentv-1.0.0", "agentv-v1.0", "agentv-v1.0.0-beta1", "agentv-v1.0.0-rc", "agentv-v1.0.0-rc1x", "agentv-v1.0.0rc1",
            "xagentv-v1.0.0", "agentv-v1.0.0 x", "agentv", "tested", "some/branch", "",
        ):
            result = self.tag(tag)
            self.assertNotEqual(result.returncode, 0, f"{tag!r} gave {result.stdout!r}")
            self.assertEqual(result.stdout, "")

    def test_the_tags_a_version_can_have(self):
        for version, names in (
            ("1.0.0", ["agentv-v1.0.0"]),
            ("1.0.0-rc1", ["agentv-v1.0.0-rc1"]),
            ("0.2.0", ["agentv-v0.2.0", "v0.2.0"]),
            ("0.3.0-rc1", ["agentv-v0.3.0-rc1"]),
        ):
            result = run(BIN / "agentv-iso-tag", "--names", version)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.split(), names)
            # Each of them reads back as that version.
            for name in names:
                self.assertEqual(self.tag(name).stdout.split()[1], version)
        for version in ("1.0", "v1.0.0", "0.2.0.r5.gabc1234", "edge", ""):
            self.assertNotEqual(run(BIN / "agentv-iso-tag", "--names", version).returncode, 0)


class WhatTheIsoCarries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)
        self.packages = self.work / "packages"
        self.packages.mkdir()
        # A stand-in agentv-os with two commits.
        self.os = self.work / "agentv-os"
        self.git_env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        }
        self.git("init", "-q", "-b", "agentv", str(self.os), cwd=self.work)
        self.first = self.commit("first")
        self.second = self.commit("second")
        self.env = {**self.git_env, "AGENTV_OWNER": "someone", "AGENTV_OS_URL": str(self.os)}

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args, cwd=None):
        result = run("git", *args, env=self.git_env, cwd=cwd or self.os)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def commit(self, name):
        self.git("commit", "-q", "--allow-empty", "-m", name)
        return self.git("rev-parse", "HEAD")

    def fetched(self, version):
        for old in self.packages.iterdir():
            old.unlink()
        (self.packages / f"agentv-{version}-1-any.pkg.tar.zst").write_bytes(b"a package")
        (self.packages / "agentv-keyring-20261101-1-any.pkg.tar.zst").write_bytes(b"a keyring")

    def carries(self, tag):
        return run(BIN / "agentv-iso-carries", tag, self.packages, env=self.env)

    def passes(self, tag):
        result = self.carries(tag)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def refused(self, why, tag):
        result = self.carries(tag)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "")
        self.assertIn(why, result.stderr)

    def test_a_releases_iso_carries_the_release(self):
        self.fetched("1.0.0")
        self.assertIn("carries agentv 1.0.0", self.passes("agentv-v1.0.0"))
        self.fetched("0.2.0")
        self.passes("v0.2.0")

    def test_a_release_tagged_before_its_package_is_published_is_refused(self):
        # Stable still serves the release before: the ISO would be called
        # 1.0.0 and install 0.2.0.
        self.fetched("0.2.0")
        self.refused("would be called 1.0.0 and install 0.2.0", "agentv-v1.0.0")
        # Edge's build of the same commit isn't the release either.
        self.fetched("1.0.0.r0.g" + self.first[:9])
        self.refused("would be called 1.0.0", "agentv-v1.0.0")

    def test_a_candidates_iso_carries_the_commit_agentv_os_tagged(self):
        self.git("tag", "agentv-v1.0.0-rc1", self.first)
        self.fetched("0.2.0.r540.g" + self.first[:9])
        said = self.passes("agentv-v1.0.0-rc1")
        self.assertIn("0.2.0.r540.g" + self.first[:9], said)
        # A tag with a message of its own is followed to its commit.
        self.git("tag", "-a", "-m", "the second candidate", "agentv-v1.0.0-rc2", self.second)
        self.fetched("0.2.0.r541.g" + self.second[:7])
        self.passes("agentv-v1.0.0-rc2")

    def test_a_candidate_agentv_os_hasnt_tagged_is_refused(self):
        self.fetched("0.2.0.r540.g" + self.first[:9])
        self.refused("agentv-os has no agentv-v1.0.0-rc1 tag", "agentv-v1.0.0-rc1")
        # A branch of that name isn't the tag.
        self.git("branch", "agentv-v1.0.0-rc1", self.first)
        self.refused("agentv-os has no agentv-v1.0.0-rc1 tag", "agentv-v1.0.0-rc1")

    def test_a_candidate_whose_edge_has_moved_on_is_refused(self):
        # agentv-os tagged the first commit, and by the time the ISO was
        # built edge's package was from the second.
        self.git("tag", "agentv-v1.0.0-rc1", self.first)
        self.fetched("0.2.0.r541.g" + self.second[:9])
        self.refused("wouldn't be what was tagged", "agentv-v1.0.0-rc1")

    def test_a_candidate_needs_edges_package(self):
        self.git("tag", "agentv-v1.0.0-rc1", self.first)
        self.fetched("0.2.0")
        self.refused("doesn't say which agentv-os commit", "agentv-v1.0.0-rc1")

    def test_it_needs_one_agentv_package_and_a_release_tag(self):
        self.refused("found 0", "agentv-v1.0.0")
        self.fetched("1.0.0")
        (self.packages / "agentv-1.0.1-1-any.pkg.tar.zst").write_bytes(b"another")
        self.refused("found 2", "agentv-v1.0.0")
        self.fetched("1.0.0")
        self.assertNotEqual(self.carries("v1.0.0").returncode, 0)
        self.assertNotEqual(self.carries("some-branch").returncode, 0)

    def test_agentv_os_that_cant_be_listed_is_refused(self):
        self.fetched("0.2.0.r540.g" + self.first[:9])
        result = run(BIN / "agentv-iso-carries", "agentv-v1.0.0-rc1", self.packages, env={**self.env, "AGENTV_OS_URL": str(self.work / "nowhere")})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Couldn't list agentv-os's tags", result.stderr)


class TheIsoWorkflow(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)
        self.text = (WORKFLOWS / "iso.yml").read_text()

    def tearDown(self):
        self.tmp.cleanup()

    def decide(self, event, ref_name="agentv", **inputs):
        """Runs the step that picks the packages, and returns what it set."""
        out = self.work / "env"
        out.write_text("")
        env = {
            **os.environ,
            "GITHUB_EVENT_NAME": event, "GITHUB_REF_NAME": ref_name, "GITHUB_ENV": str(out), "GITHUB_STEP_SUMMARY": os.devnull,
            "ASKED": inputs.get("channel", ""), "KEEP": inputs.get("keep", ""), "ONLY": inputs.get("checks", ""),
        }
        result = run("bash", "-e", "-c", step("iso.yml", "Which packages, and whether the ISO is kept"), env=env, cwd=ROOT)
        return result, dict(line.split("=", 1) for line in out.read_text().splitlines())

    def test_both_kinds_of_tag_start_it(self):
        self.assertIn('    tags: ["agentv-v*", "v*"]\n', self.text)

    def test_a_releases_tag_carries_stable_and_is_kept(self):
        for tag, version in (("agentv-v1.0.0", "1.0.0"), ("v0.2.0", "0.2.0")):
            result, env = self.decide("push", tag)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(env, {"ISO_VERSION": version, "RELEASE_TAG": tag, "CHANNEL": "stable", "KEEP_ISO": "true"})

    def test_a_candidates_tag_carries_edge_and_is_kept(self):
        result, env = self.decide("push", "agentv-v1.0.0-rc1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(env, {"ISO_VERSION": "1.0.0-rc1", "RELEASE_TAG": "agentv-v1.0.0-rc1", "CHANNEL": "edge", "KEEP_ISO": "true"})

    def test_any_other_pushed_tag_fails_the_run(self):
        for tag in ("v1.0.0", "v4.5.0", "v1.0.0-rc1", "agentv-vnext", "vanything"):
            result, env = self.decide("push", tag)
            self.assertNotEqual(result.returncode, 0, tag)
            self.assertNotIn("KEEP_ISO", env)
            self.assertIn("isn't one of AgenTV's release tags", result.stdout + result.stderr)

    def test_a_run_by_hand_on_a_tag_isnt_a_release(self):
        # It can build another ref than the one it runs on.
        result, env = self.decide("workflow_dispatch", "agentv-v1.0.0", channel="edge", keep="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(env, {"RELEASE_TAG": "", "CHANNEL": "edge", "KEEP_ISO": "true"})
        result, env = self.decide("workflow_dispatch", "agentv-v1.0.0", channel="stable", keep="false")
        self.assertEqual(env, {"RELEASE_TAG": "", "CHANNEL": "stable", "KEEP_ISO": "false"})

    def test_a_pull_request_carries_edge_and_keeps_nothing(self):
        result, env = self.decide("pull_request", "12/merge")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(env, {"RELEASE_TAG": "", "CHANNEL": "edge", "KEEP_ISO": "false"})

    def test_a_run_of_only_some_checks_keeps_nothing(self):
        _, env = self.decide("workflow_dispatch", channel="edge", keep="true", checks="s0.1-iso")
        self.assertEqual(env["KEEP_ISO"], "false")

    def test_the_package_is_checked_against_the_tag_before_the_build(self):
        fetch = self.text.index("- name: Fetch AgenTV's signed packages")
        check = self.text.index("- name: The packages are the ones the tag stands for")
        build = self.text.index("- name: Build, install, boot, check")
        self.assertLess(fetch, check)
        self.assertLess(check, build)
        body = self.text[check:build]
        self.assertIn("if: env.RELEASE_TAG != ''", body)
        self.assertIn('bin/agentv-iso-carries "$RELEASE_TAG"', body)
        # A pipe to the summary mustn't hide a refusal.
        self.assertIn("set -o pipefail", body)

    def name(self, tag="", version=""):
        repo = self.work / "repo"
        if not repo.exists():
            (repo / "release").mkdir(parents=True)
            env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
            for args in (("init", "-q"), ("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "built")):
                self.assertEqual(run("git", *args, env=env, cwd=repo).returncode, 0)
        for old in (repo / "release").iterdir():
            old.unlink()
        (repo / "release" / "omarchy-built.iso").write_bytes(b"an ISO")
        out = self.work / "out"
        out.write_text("")
        env = {
            **os.environ, "RELEASE_TAG": tag, "ISO_VERSION": version, "GITHUB_SHA": "f" * 40,
            "GITHUB_REF": "refs/tags/agentv-v9.9.9", "GITHUB_REF_NAME": "agentv-v9.9.9",
            "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": os.devnull,
        }
        result = run("bash", "-e", "-c", step("iso.yml", "Name the ISO"), env=env, cwd=repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        name = dict(line.split("=", 1) for line in out.read_text().splitlines())["name"]
        self.assertEqual(sorted(p.name for p in (repo / "release").iterdir()), [f"{name}.iso", f"{name}.iso.sha256"])
        digest = hashlib.sha256(b"an ISO").hexdigest()
        self.assertEqual((repo / "release" / f"{name}.iso.sha256").read_text(), f"{digest}  {name}.iso\n")
        return name, run("git", "rev-parse", "HEAD", cwd=repo).stdout.strip()

    def test_a_tags_iso_is_named_for_its_version(self):
        self.assertEqual(self.name("agentv-v1.0.0", "1.0.0")[0], "agentv-1.0.0-x86_64")
        self.assertEqual(self.name("agentv-v1.0.0-rc1", "1.0.0-rc1")[0], "agentv-1.0.0-rc1-x86_64")
        self.assertEqual(self.name("v0.2.0", "0.2.0")[0], "agentv-0.2.0-x86_64")

    def test_any_other_iso_is_named_for_the_commit_it_built(self):
        # Not for the ref it runs on, a tag included, nor for the commit
        # that ref is on: a run by hand can build another.
        name, built = self.name()
        self.assertEqual(name, f"agentv-edge-{built[:7]}-x86_64")

    def test_it_has_no_keys(self):
        code = "\n".join(line for line in self.text.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("secrets.", code)
        self.assertNotIn("environment:", code)


class ThePublishWorkflow(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def which(self, tag, repo="someone/agentv-iso"):
        """Runs the step that decides, for the ISO workflow's run of a tag."""
        out = self.work / "out"
        out.write_text("")
        env = {
            **os.environ,
            "GH_TOKEN": "token", "OWNER": "someone", "GITHUB_REPOSITORY": "someone/agentv-iso", "EVENT": "workflow_run",
            "TAG": tag, "TAG_RUN": "7", "TAG_REPO": repo, "IN_CHANNEL": "", "IN_REPO": "", "IN_RUN": "", "IN_NAME": "",
            "R2_BUCKET": "bucket", "ISO_URL": "https://downloads.example.invalid", "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": os.devnull,
        }
        result = run("bash", "-e", "-c", step("publish-iso.yml", "Decide, and say why"), env=env, cwd=ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split("=", 1) for line in out.read_text().splitlines())

    def test_a_candidates_tag_publishes_to_rc(self):
        self.assertEqual(
            self.which("agentv-v1.0.0-rc1"),
            {"publish": "true", "channel": "rc", "repo": "agentv-iso", "run-id": "7", "name": "agentv-1.0.0-rc1-x86_64"},
        )

    def test_a_releases_tag_publishes_to_stable(self):
        self.assertEqual(self.which("agentv-v1.0.0")["channel"], "stable")
        self.assertEqual(self.which("agentv-v1.0.0")["name"], "agentv-1.0.0-x86_64")
        self.assertEqual(self.which("v0.2.0")["name"], "agentv-0.2.0-x86_64")

    def test_any_other_tag_publishes_nothing(self):
        for tag in ("v1.0.0", "v1.0.0-rc1", "v4.5.0", "agentv-vnext", "agentv"):
            self.assertEqual(self.which(tag), {"publish": "false"}, tag)

    def test_another_repos_run_publishes_nothing(self):
        self.assertEqual(self.which("agentv-v1.0.0", repo="someone-else/agentv-iso"), {"publish": "false"})

    def test_only_a_run_by_hand_can_go_back(self):
        text = (WORKFLOWS / "publish-iso.yml").read_text()
        self.assertIn("AGENTV_ISO_GO_BACK: ${{ github.event_name == 'workflow_dispatch' && inputs.back && '1' || '' }}", text)
        self.assertEqual(text.count("AGENTV_ISO_GO_BACK"), 1)

    def test_the_release_is_found_by_its_tag_and_a_candidates_is_made(self):
        notes = step("publish-iso.yml", "Put the download link and the checksum in the release's notes")
        self.assertIn('bin/agentv-iso-tag --names "$version"', notes)
        self.assertNotIn('"v$version"', notes)
        # A pre-release, only for a candidate, and only for a tag that's there.
        made = notes[notes.index("gh release create"):]
        self.assertIn("--verify-tag --prerelease", made)
        self.assertEqual(notes.count("gh release create"), 1)
        self.assertIn('if [[ -z $tag && $CHANNEL == "rc" ]]; then', notes)


class TheNotes(unittest.TestCase):
    URL = "https://downloads.example.invalid/iso/"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)
        self.env = {**os.environ, "AGENTV_OWNER": "someone"}
        self.env.pop("AGENTV_RUN_URL", None)

    def tearDown(self):
        self.tmp.cleanup()

    def checksum(self, name, signed=True):
        path = self.work / f"{name}.iso.sha256"
        path.write_text(f"{'ab' * 32}  {name}.iso\n")
        sig = Path(f"{path}.sig")
        if signed:
            sig.write_bytes(b"a signature")
        elif sig.exists():
            sig.unlink()
        return path

    def notes(self, mode, name, *more, signed=True, url=None, **env):
        return run(BIN / "agentv-iso-notes", mode, self.checksum(name, signed), url or f"{self.URL}{name}.iso", *more, env={**self.env, **env})

    def test_the_part_has_the_download_the_checksum_and_the_check(self):
        result = self.notes("block", "agentv-1.0.0-rc1-x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], "<!-- iso -->")
        self.assertEqual(lines[-1], "<!-- /iso -->")
        self.assertIn(f"Download the ISO: [agentv-1.0.0-rc1-x86_64.iso]({self.URL}agentv-1.0.0-rc1-x86_64.iso)", lines)
        self.assertIn(f"SHA-256 of the ISO: `{'ab' * 32}`", lines)
        for line in (
            f"curl -LO {self.URL}agentv-1.0.0-rc1-x86_64.iso.sha256",
            f"curl -LO {self.URL}agentv-1.0.0-rc1-x86_64.iso.sha256.sig",
            "curl -LO https://raw.githubusercontent.com/someone/agentv-pkgs/main/agentv-keyring/agentv.gpg",
            "gpg --import agentv.gpg",
            "gpg --verify agentv-1.0.0-rc1-x86_64.iso.sha256.sig agentv-1.0.0-rc1-x86_64.iso.sha256",
            "sha256sum -c agentv-1.0.0-rc1-x86_64.iso.sha256",
        ):
            self.assertIn(line, lines)
        # The key it names is the one this repo pins.
        pinned = (ROOT / "configs/airootfs/usr/share/agentv-iso/key-fingerprint").read_text().strip()
        said = re.search(r"from the key `([0-9A-F ]+)`", result.stdout).group(1)
        self.assertEqual(said.replace(" ", ""), pinned)

    def test_an_unsigned_checksum_gets_no_signature_lines(self):
        result = self.notes("block", "agentv-1.0.0-x86_64", signed=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("gpg", result.stdout)
        self.assertNotIn(".sig", result.stdout)
        self.assertIn("sha256sum -c agentv-1.0.0-x86_64.iso.sha256", result.stdout)
        self.assertIn("isn't signed yet", result.stdout)

    def test_the_part_goes_at_the_end_of_the_notes_as_written(self):
        written = self.work / "notes.md"
        written.write_text("AgenTV 1.0.0, the first release.\n\nWhat's in it is on agentv-os.\n\n\n")
        result = self.notes("into", "agentv-1.0.0-x86_64", written)
        self.assertEqual(result.returncode, 0, result.stderr)
        block = self.notes("block", "agentv-1.0.0-x86_64").stdout
        self.assertEqual(result.stdout, "AgenTV 1.0.0, the first release.\n\nWhat's in it is on agentv-os.\n\n" + block)

    def test_publishing_again_replaces_the_part_and_keeps_the_rest(self):
        written = self.work / "notes.md"
        written.write_text("My own words.\n")
        once = self.notes("into", "agentv-1.0.0-x86_64", written, signed=False).stdout
        written.write_text(once + "\nA line added by hand afterwards.\n")
        again = self.notes("into", "agentv-1.0.0-x86_64", written).stdout
        self.assertEqual(again.count("<!-- iso -->"), 1)
        self.assertEqual(again.count("Download the ISO: "), 1)
        self.assertIn("gpg --verify", again)
        self.assertNotIn("isn't signed yet", again)
        self.assertTrue(again.startswith("My own words.\n"))
        self.assertIn("A line added by hand afterwards.", again)
        # The same thing again changes nothing.
        written.write_text(again)
        self.assertEqual(self.notes("into", "agentv-1.0.0-x86_64", written).stdout, again)

    def test_the_two_lines_older_releases_had_are_replaced(self):
        written = self.work / "notes.md"
        written.write_text("AgenTV 0.2.0's installer.\n\nDownload the ISO: [agentv-stable.iso](https://old.example.invalid/agentv-stable.iso)\n\nSHA-256 of the ISO: `" + "cd" * 32 + "`\n\n")
        result = self.notes("into", "agentv-0.2.0-x86_64", written).stdout
        self.assertNotIn("agentv-stable.iso", result)
        self.assertNotIn("cd" * 32, result)
        self.assertEqual(result.count("Download the ISO: "), 1)

    def test_a_candidates_own_notes(self):
        result = self.notes("candidate", "agentv-1.0.0-rc1-x86_64", AGENTV_RUN_URL="https://github.com/someone/agentv-iso/actions/runs/7")
        self.assertEqual(result.returncode, 0, result.stderr)
        said = result.stdout
        self.assertTrue(said.startswith("AgenTV 1.0.0-rc1's installer, powered by Omarchy. It's a release candidate: what 1.0.0 will be"))
        self.assertIn("`agentv channel stable`", said)
        self.assertIn("[This tag's run](https://github.com/someone/agentv-iso/actions/runs/7)", said)
        self.assertTrue(said.endswith(self.notes("block", "agentv-1.0.0-rc1-x86_64").stdout))
        # Only a candidate gets notes written for it.
        self.assertNotEqual(self.notes("candidate", "agentv-1.0.0-x86_64").returncode, 0)

    def test_it_takes_only_an_isos_checksum_and_its_address(self):
        self.assertNotEqual(self.notes("block", "agentv-1.0.0-x86_64", url="https://downloads.example.invalid/iso/other.iso").returncode, 0)
        self.assertNotEqual(self.notes("block", "agentv-1.0.0-x86_64", url="http://downloads.example.invalid/iso/agentv-1.0.0-x86_64.iso").returncode, 0)
        self.assertNotEqual(self.notes("block", "agentv-1.0.0-x86_64", url=f"{self.URL}agentv-1.0.0-x86_64.iso) [x](https://evil.example").returncode, 0)
        bad = self.work / "bad.iso.sha256"
        bad.write_text("not a checksum\n")
        self.assertNotEqual(run(BIN / "agentv-iso-notes", "block", bad, f"{self.URL}agentv-1.0.0-x86_64.iso", env=self.env).returncode, 0)


if __name__ == "__main__":
    unittest.main()
