# AgenTV

This repo is `agentv-iso`: the installer ISO for AgenTV, built on top of Omarchy. It's a fork of `omacom/omarchy-iso`, pinned to upstream commit `81fd667`. It builds Omarchy's installer, pointed at `agentv-os` instead of plain Omarchy. Omarchy's own `AGENTS.md` and README here still apply. This file adds what's different for AgenTV, and when the two disagree, this file wins.

The plan lives in `../agentic-tv-os`: read `HANDOFF.md` first ("Next: stage 0" is the to-do list here). AgenTV's skills live in `../agentv-os/.claude/skills/`. Start the session in `agentv-os` with this repo added, or read them there. The ones that matter most here are:
- `agentv-quality-gates`;
- `agentv-acceptance-tests` (the image test);
- `agentv-install-scripts`.

## Rules

- **Never edit upstream files.** Only add: our workflow, the settings that point the build at `agentv-os`, and the installer logo. Check with `git diff --diff-filter=MDR --name-only 81fd667...HEAD`, which must print nothing.
- **Disable upstream's `nightly-build`, `install-test-comment` and `upgrade-test` workflows before Actions runs anything.** They publish to Omarchy's bucket or use runners we don't have.
- **The owner name lives in one build setting,** never in code, so the repos can move to an organisation later.
- **Build and test the ISO in CI only.** The Mac can't run the x86_64 ISO, and it has little free disk. The ISO is about 6.4 GB, so it travels as a workflow artifact, not a release asset.
- **No secrets** in the repo. The signing key and test keys live as GitHub Actions secrets.
- **Copy** follows Omarchy's voice, "coming soon" for planned things, "Powered by Omarchy", and no em dashes anywhere.
- **Commit** with this repo's own git identity, and end the message with the Co-Authored-By trailer. Log progress in `../agentic-tv-os/LOG.md`.
