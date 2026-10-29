<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../branding/logo.svg">
    <img alt="AgenTV" src="../branding/logo-light.svg" width="520">
  </picture>
</p>

<p align="center">
  <b>The installer for AgenTV, the world's first open-source agentic TV OS.</b><br>
  Powered by <a href="https://omarchy.org">Omarchy</a>.
</p>

---

This is where the AgenTV USB stick comes from.

It's Omarchy's installer, pointed at [`agentv-os`](https://github.com/radomird/agentv-os) instead of plain Omarchy. Same questions, AgenTV's logo up top. When it's done, the box reboots into TV setup and you take it from there on your phone.

The latest is [the 0.1.3 ISO](https://pub-18fa48b004b845838c98225b8955c7e6.r2.dev/iso/agentv-0.1.3-x86_64.iso) (about 6.5 GB), with [its checksum](https://pub-18fa48b004b845838c98225b8955c7e6.r2.dev/iso/agentv-0.1.3-x86_64.iso.sha256). It's over GitHub's limit for release files, so it lives in AgenTV's Cloudflare R2 bucket, and each [release](https://github.com/radomird/agentv-iso/releases) links to its own. A release tag's run puts it there (`bin/agentv-iso-publish`).

Every ISO passes a test run in GitHub Actions before you see it: a VM installs it by itself, then boots what it installed into AgenTV's TV session.

## Powered by Omarchy

- **This repo** is a fork of [omacom/omarchy-iso](https://github.com/omacom/omarchy-iso), pinned to an upstream commit.
- **What it installs:** it builds Omarchy's installer, pointed at [`agentv-os`](https://github.com/radomird/agentv-os), the TV OS.
- **Omarchy's files are never edited here.** AgenTV only adds its own: the build workflow, the settings that point the build at `agentv-os`, and the installer logo.
- **Omarchy's own README**, with how to build and test an ISO, is [`../README.md`](../README.md).
- **Omarchy and its installer are MIT-licensed.** The [licence](../LICENSE) is kept as it is.
- **Not official:** AgenTV isn't made or endorsed by the Omarchy project.
