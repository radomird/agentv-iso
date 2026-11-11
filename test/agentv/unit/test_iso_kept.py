"""bin/agentv-iso-kept: the run an ISO is taken from is looked at before the
ISO is published. Which repo and workflow made it, what started it and on
what, whether it passed, whether a release tag's commit is on agentv, and
whether the ISO's name is the one that run was for.

A stand-in for gh is first on PATH. It answers "gh api <path>" from a folder
of files, one for each address, and writes down every call. Nothing here
asks GitHub."""

import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
KEPT = ROOT / "bin" / "agentv-iso-kept"
WORKFLOW = ROOT / ".github" / "workflows" / "publish-iso.yml"

GH = r'''#!{python}
import os, sys
from pathlib import Path

args = [arg for arg in sys.argv[1:] if arg != "--paginate"]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
if len(args) != 2 or args[0] != "api":
    sys.exit("the stand-in doesn't know: " + " ".join(args))
answer = Path(os.environ["FAKE_GITHUB"]) / args[1].replace("/", "_").replace("?", "_")
if not answer.is_file():
    sys.exit("gh: Not Found (HTTP 404)")
sys.stdout.write(answer.read_text())
'''

OWNER = "someone"
TAG_COMMIT = "a" * 40
NIGHT_COMMIT = "b" * 40


class IsoKept(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)
        self.github = self.work / "github"
        self.github.mkdir()
        self.log = self.work / "gh.log"
        self.log.write_text("")
        bin_dir = self.work / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(GH.replace("{python}", sys.executable))
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_GITHUB": str(self.github),
            "FAKE_LOG": str(self.log),
            "GITHUB_REPOSITORY_OWNER": OWNER,
        }

    def tearDown(self):
        self.tmp.cleanup()

    def answer(self, path, value):
        (self.github / path.replace("/", "_").replace("?", "_")).write_text(json.dumps(value))

    def a_run(self, repo, run, kept, **changes):
        """A run as GitHub describes it, and what it kept."""
        record = {
            "repository": {"full_name": f"{OWNER}/{repo}"},
            "head_repository": {"full_name": f"{OWNER}/{repo}"},
            "status": "completed",
            "conclusion": "success",
            **changes,
        }
        self.answer(f"repos/{OWNER}/{repo}/actions/runs/{run}", record)
        self.answer(
            f"repos/{OWNER}/{repo}/actions/runs/{run}/artifacts?per_page=100",
            {"artifacts": [{"name": name, "expired": False} for name in kept]},
        )

    def a_tags_run(self, tag="v1.0.0", kept=None, on_agentv="ahead", **changes):
        version = tag.removeprefix("v")
        kept = [f"agentv-{version}-x86_64", f"agentv-{version}-x86_64.sha256"] if kept is None else kept
        record = {"path": ".github/workflows/iso.yml", "event": "push", "head_branch": tag, "head_sha": TAG_COMMIT, **changes}
        self.a_run("agentv-iso", 7, kept, **record)
        self.answer(f"repos/{OWNER}/agentv-iso/compare/{record['head_sha']}...agentv", {"status": on_agentv})

    def a_night(self, kept=("agentv-0.2.0.r422.g155320d30-x86_64",), **changes):
        record = {"path": ".github/workflows/nightly.yml", "event": "schedule", "head_branch": "agentv", "head_sha": NIGHT_COMMIT, **changes}
        self.a_run("agentv-os", 9, list(kept), **record)

    def kept(self, channel, repo, run, name):
        return subprocess.run([str(KEPT), channel, repo, str(run), name], env=self.env, capture_output=True, text=True)

    def passes(self, *args):
        result = self.kept(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def refused(self, why, *args):
        result = self.kept(*args)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "")
        self.assertIn(why, result.stderr)

    # --- a release tag's run -------------------------------------------------

    def test_a_release_tags_run_is_stable(self):
        self.a_tags_run()
        said = self.passes("stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")
        self.assertIn("agentv-1.0.0-x86_64", said)
        self.assertIn("started by push on `v1.0.0`", said)

    def test_a_release_candidates_run_is_rc(self):
        self.a_tags_run("v1.0.0-rc2")
        self.passes("rc", "agentv-iso", 7, "agentv-1.0.0-rc2-x86_64")

    def test_a_tag_on_agentvs_newest_commit_counts(self):
        self.a_tags_run(on_agentv="identical")
        self.passes("stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")

    def test_a_tag_on_a_commit_agentv_doesnt_have_is_refused(self):
        for status in ("diverged", "behind"):
            self.a_tags_run(on_agentv=status)
            self.refused("which the agentv branch doesn't have", "stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")

    def test_no_answer_about_the_tags_commit_is_refused(self):
        self.a_tags_run()
        (self.github / f"repos_{OWNER}_agentv-iso_compare_{TAG_COMMIT}...agentv").unlink()
        self.refused("Couldn't ask whether agentv has v1.0.0's commit", "stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")

    def test_a_run_started_by_hand_is_never_a_release(self):
        # On a tag too: it can build another ref than the one it runs on.
        self.a_tags_run(event="workflow_dispatch")
        self.refused("was started by workflow_dispatch", "stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")

    def test_the_tag_says_which_channel(self):
        self.a_tags_run("v1.0.0-rc1")
        self.refused("isn't a release tag", "stable", "agentv-iso", 7, "agentv-1.0.0-rc1-x86_64")
        self.a_tags_run("v1.0.0")
        self.refused("isn't a release candidate's tag", "rc", "agentv-iso", 7, "agentv-1.0.0-x86_64")
        self.a_tags_run("some-branch")
        self.refused("isn't a release tag", "stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")

    def test_the_name_is_the_tags_version(self):
        self.a_tags_run("v1.0.0", kept=["agentv-9.9.9-x86_64"])
        self.refused("its ISO is agentv-1.0.0-x86_64, not agentv-9.9.9-x86_64", "stable", "agentv-iso", 7, "agentv-9.9.9-x86_64")

    def test_a_release_comes_from_the_iso_workflow_in_agentv_iso(self):
        self.a_tags_run(path=".github/workflows/other.yml")
        self.refused("comes from agentv-iso's ISO workflow", "stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")
        self.a_night(kept=["agentv-1.0.0-x86_64"])
        self.refused("comes from agentv-iso's ISO workflow", "stable", "agentv-os", 9, "agentv-1.0.0-x86_64")

    # --- a night's run -------------------------------------------------------

    def test_a_scheduled_nights_iso_is_edge(self):
        self.a_night()
        self.passes("edge", "agentv-os", 9, "agentv-0.2.0.r422.g155320d30-x86_64")
        self.a_night(kept=["agentv-edge-2026.11.10-abc1234-x86_64"])
        self.passes("edge", "agentv-os", 9, "agentv-edge-2026.11.10-abc1234-x86_64")

    def test_a_night_started_by_hand_or_on_another_branch_is_refused(self):
        self.a_night(event="workflow_dispatch")
        self.refused("was started by workflow_dispatch", "edge", "agentv-os", 9, "agentv-0.2.0.r422.g155320d30-x86_64")
        self.a_night(head_branch="some-branch")
        self.refused("on `some-branch`", "edge", "agentv-os", 9, "agentv-0.2.0.r422.g155320d30-x86_64")

    def test_another_workflows_iso_is_never_edge(self):
        self.a_night(path=".github/workflows/image.yml", event="workflow_dispatch")
        self.refused("comes from agentv-os's Nightly workflow", "edge", "agentv-os", 9, "agentv-0.2.0.r422.g155320d30-x86_64")

    def test_an_iso_run_by_hand_in_agentv_iso_is_never_edge(self):
        # Its record doesn't say which branch or commit it built.
        self.a_run(
            "agentv-iso", 7, ["agentv-edge-abc1234-x86_64"],
            path=".github/workflows/iso.yml", event="workflow_dispatch", head_branch="agentv", head_sha=TAG_COMMIT,
        )
        self.refused("A run started by hand can build a branch that isn't merged", "edge", "agentv-iso", 7, "agentv-edge-abc1234-x86_64")

    def test_edge_takes_only_an_edge_name(self):
        self.a_night(kept=["agentv-1.0.0-x86_64"])
        self.refused("isn't an edge ISO's name", "edge", "agentv-os", 9, "agentv-1.0.0-x86_64")

    # --- either --------------------------------------------------------------

    def test_a_run_that_didnt_pass_is_refused(self):
        for changes in ({"conclusion": "failure"}, {"conclusion": "cancelled"}, {"status": "in_progress", "conclusion": None}):
            self.a_tags_run(**changes)
            self.refused("didn't pass", "stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")
            self.a_night(**changes)
            self.refused("didn't pass", "edge", "agentv-os", 9, "agentv-0.2.0.r422.g155320d30-x86_64")

    def test_a_run_from_another_repos_code_is_refused(self):
        self.a_tags_run(head_repository={"full_name": "someone-else/agentv-iso"})
        self.refused("isn't agentv-iso's own", "stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")

    def test_a_run_that_isnt_there_is_refused(self):
        self.refused("Couldn't read agentv-iso's run 7", "stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")

    def test_the_run_has_to_still_have_that_iso(self):
        self.a_tags_run(kept=["agentv-1.0.0-x86_64.sha256", "iso-test-7-1"])
        self.refused("has no ISO called agentv-1.0.0-x86_64", "stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")
        self.a_night()
        self.answer(
            f"repos/{OWNER}/agentv-os/actions/runs/9/artifacts?per_page=100",
            {"artifacts": [{"name": "agentv-0.2.0.r422.g155320d30-x86_64", "expired": True}]},
        )
        self.refused("has no ISO called", "edge", "agentv-os", 9, "agentv-0.2.0.r422.g155320d30-x86_64")

    def test_it_takes_only_what_the_workflow_hands_it(self):
        for args in (
            ("nightly", "agentv-iso", 7, "agentv-1.0.0-x86_64"),
            ("stable", "agentv-apps", 7, "agentv-1.0.0-x86_64"),
            ("stable", "agentv-iso", "7/../8", "agentv-1.0.0-x86_64"),
            ("stable", "agentv-iso", 7, "agentv-1.0.0-x86_64/../x"),
        ):
            result = self.kept(*args)
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text(), "")

    def test_it_only_reads(self):
        self.a_tags_run()
        self.passes("stable", "agentv-iso", 7, "agentv-1.0.0-x86_64")
        for call in self.log.read_text().splitlines():
            self.assertRegex(call, r"^api repos/someone/agentv-iso/(actions/runs/7(/artifacts\?per_page=100)?|compare/a{40}\.\.\.agentv)$")


def jobs():
    """Each job's text, by name, without its comments."""
    text = WORKFLOW.read_text()
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


class TheWorkflowAsksFirst(unittest.TestCase):
    def test_the_run_is_checked_in_the_job_with_no_secrets(self):
        which = jobs()["which"]
        decide = which.index("id: which")
        check = which.index('bin/agentv-iso-kept "$CHANNEL" "$REPO" "$RUN_ID" "$NAME"')
        self.assertLess(decide, check)
        self.assertNotIn("secrets.", which)
        self.assertNotIn("environment:", which)
        # It checks what the step before decided, not the inputs again.
        step = which[which.index("- name: Check the run that kept it"):]
        for name, output in (("CHANNEL", "channel"), ("REPO", "repo"), ("RUN_ID", "run-id"), ("NAME", "name")):
            self.assertIn(f"{name}: ${{{{ steps.which.outputs.{output} }}}}", step)
        # A pipe to the summary mustn't hide a refusal.
        self.assertIn("set -o pipefail", step)

    def test_a_tags_run_and_a_run_by_hand_are_both_checked(self):
        which = jobs()["which"]
        step = which[which.index("- name: Check the run that kept it"):]
        condition = re.search(r"^\s+if: (.+)$", step, re.M).group(1)
        self.assertEqual(condition, "steps.which.outputs.publish == 'true' && github.event_name != 'schedule'")

    def test_every_job_with_a_key_waits_for_it(self):
        found = jobs()
        self.assertRegex(found["sum"], r"needs: which\n")
        self.assertRegex(found["sign"], r"needs: \[which, sum\]\n")
        self.assertRegex(found["publish"], r"needs: \[which, sign\]\n")
        # None of them runs when the job before it failed.
        for name in ("sum", "sign", "publish"):
            self.assertNotIn("always()", found[name])
            self.assertNotIn("!cancelled()", found[name])
            self.assertNotIn("failure()", found[name])


if __name__ == "__main__":
    unittest.main()
