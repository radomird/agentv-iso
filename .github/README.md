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

This repo builds the AgenTV installer ISO. Boot it from a USB stick and answer Omarchy's own installer questions. The box then restarts into AgenTV's TV setup, which you finish from your phone. The installer shows the AgenTV logo, with "powered by omarchy" underneath.

**Status:** early. No ISO has been built yet. Each ISO will be built and install-tested in GitHub Actions: an unattended install in a VM, then a boot of the installed system.

## Powered by Omarchy

- **This repo** is a fork of [omacom/omarchy-iso](https://github.com/omacom/omarchy-iso), pinned to an upstream commit.
- **What it installs:** it builds Omarchy's installer, pointed at [`agentv-os`](https://github.com/radomird/agentv-os), the TV OS.
- **Omarchy's files are never edited here.** AgenTV only adds its own: the build workflow, the settings that point the build at `agentv-os`, and the installer logo.
- **Omarchy's own README**, with how to build and test an ISO, is [`../README.md`](../README.md).
- **Omarchy and its installer are MIT-licensed.** The [licence](../LICENSE) is kept as it is.
- **Not official:** AgenTV isn't made or endorsed by the Omarchy project.
