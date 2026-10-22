# AgenTV

This repo is `agentv-iso`: the installer ISO for AgenTV, built on top of Omarchy. It's a fork of `omacom/omarchy-iso` that follows upstream's `quattro` whenever Omarchy has a new stable release (ADR-026). The upstream commit it's on is in `.github/omarchy-base`, and the Omarchy release that went with it in `.github/omarchy-release`. It builds Omarchy's own installer with Omarchy's own packages, and adds AgenTV's signed packages beside them (ADR-025). Omarchy's own `AGENTS.md` and README here still apply. This file adds what's different for AgenTV, and when the two disagree, this file wins.

The plan lives in `../agentic-tv-os`: read `HANDOFF.md` first ("Next: stage 0" is the to-do list here). AgenTV's skills live in `../agentv-os/.claude/skills/`. Start the session in `agentv-os` with this repo added, or read them there. The ones that matter most here are:
- `agentv-quality-gates`;
- `agentv-acceptance-tests` (the image test);
- `agentv-install-scripts`.

## Rules

- **Never edit upstream files.** Only add: our workflows, the build step that adds AgenTV's packages and logo (`configs/airootfs/root/customize_airootfs.sh` and `configs/airootfs/usr/share/agentv-iso/`), and our tests in `test/agentv/`. Check with `bin/agentv-check`; its first check is the same as `git diff --diff-filter=MDR --name-only "$(cat .github/omarchy-base)"...HEAD` printing nothing.
- **What the ISO shows is AgenTV's, at build time only** (ADR-027, ADR-028). `bin/agentv-iso-brand` changes the name, volume label and boot menu titles in the working tree for one build, and `test/agentv/image/ci` puts upstream's files back. The live system's greeter, step headers and finish screen are changed by `customize.sh` inside the ISO. Each change stops the build if upstream has moved its line; fix the step, never the upstream file.
- **Upstream's own workflows stay off,** except the ones `.github/upstream-workflows-kept` names (its unit tests). They publish to Omarchy's bucket or use runners we don't have. They're switched off through the API, never by editing them, and the Omarchy sync switches off any new ones.
- **The owner name is never in code.** Workflows read it from GitHub's own context, so the repos can move to an organisation later.
- **Build and test the ISO in CI only.** The Mac can't run the x86_64 ISO, and it has little free disk. The ISO is about 6.4 GB, so it travels as a workflow artifact, not a release asset.
- **No secrets** in the repo. The signing key and test keys live as GitHub Actions secrets.
- **Copy** follows Omarchy's voice, "coming soon" for planned things, "Powered by Omarchy", and no em dashes anywhere.
- **Commit** with this repo's own git identity, and end the message with the Co-Authored-By trailer. Log progress in `../agentic-tv-os/LOG.md`.
