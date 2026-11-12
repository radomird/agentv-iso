"""Every script a workflow step runs has to be something bash can read.

GitHub hands a step's "run:" text to bash as it is, and bash reads a whole
if or case before it runs any of it. So one stray quote stops the step
whatever started the workflow, and nothing says so until that step runs.
The publish workflow had one for a day: an apostrophe inside a
${name:-words} default, which bash takes as the start of a quoted string.
This reads every workflow here and asks bash to parse each script,
running none of them."""

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS = ROOT / ".github" / "workflows"


def scripts(workflow):
    """Each "run: |" block of a workflow, as (line number, text)."""
    lines = workflow.read_text().splitlines()
    found = []
    i = 0
    while i < len(lines):
        match = re.match(r"^(\s*)(- )?run: \|\s*$", lines[i])
        if not match:
            i += 1
            continue
        indent = len(match.group(1)) + (2 if match.group(2) else 0) + 2
        body = []
        j = i + 1
        while j < len(lines) and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip()) >= indent):
            body.append(lines[j][indent:])
            j += 1
        found.append((i + 1, "\n".join(body) + "\n"))
        i = j
    return found


class WorkflowScripts(unittest.TestCase):
    def test_bash_can_read_every_step(self):
        read = 0
        for workflow in sorted(WORKFLOWS.glob("*.yml")):
            for line, text in scripts(workflow):
                result = subprocess.run(["bash", "-n"], input=text, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, f"{workflow.name}, the step at line {line}: {result.stderr}")
                read += 1
        # It found the scripts at all.
        self.assertGreater(read, 20)

    def test_it_would_catch_the_apostrophe(self):
        text = 'passed=""\necho "It kept an ISO. ${passed:-Its jobs couldn\'t be read.}"\n'
        self.assertNotEqual(subprocess.run(["bash", "-n"], input=text, capture_output=True, text=True).returncode, 0)

    def test_it_reads_the_publish_step_that_decides(self):
        publish = dict(scripts(WORKFLOWS / "publish-iso.yml"))
        self.assertTrue(any("bin/agentv-iso-passed edge" in text for text in publish.values()))


if __name__ == "__main__":
    unittest.main()
