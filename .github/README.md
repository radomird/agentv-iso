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

It's Omarchy's own installer, set up to install AgenTV instead of plain Omarchy. You get the same questions, with AgenTV's logo at the top. When it's done, your box reboots into AgenTV, and TV setup starts on the TV. Scan its code with your phone, and setup takes it from there.

## Getting the ISO

The latest is [the 0.1.4 ISO](https://pub-18fa48b004b845838c98225b8955c7e6.r2.dev/iso/agentv-0.1.4-x86_64.iso) (about 6.6 GB). Grab [its checksum](https://pub-18fa48b004b845838c98225b8955c7e6.r2.dev/iso/agentv-0.1.4-x86_64.iso.sha256) too, so you can check the download. [agentv-os's README](https://github.com/radomird/agentv-os#installing-it) walks you through putting it on a USB stick and installing.

The ISO is too big for GitHub's release files, so it lives on Cloudflare R2, and each [release](https://github.com/radomird/agentv-iso/releases) here links to its own.

## How an ISO gets made

Every release tag builds the ISO here and puts it on R2 (`bin/agentv-iso-publish`). Before you see it, it has to pass a test run in GitHub Actions: a VM installs it by itself, then boots what it installed into AgenTV's TV session.

## Support AgenTV

AgenTV is free and open source. If you'd like to help, you can [chip in through Stripe](https://buy.stripe.com/7sY4gzeMjdZs1oo7Wbgfu00) and pick the amount yourself. Thank you!

## Powered by Omarchy

This repo is a fork of [omacom/omarchy-iso](https://github.com/omacom/omarchy-iso), pinned to an upstream commit. I never edit Omarchy's files here. AgenTV only adds its own: the build workflow, the settings that point the build at [`agentv-os`](https://github.com/radomird/agentv-os), and the installer logo. Omarchy's own README, with how to build and test an ISO yourself, is at [`../README.md`](../README.md).

Omarchy and its installer are MIT-licensed, and the [licence](../LICENSE) stays as it is. AgenTV isn't made or endorsed by the Omarchy project.
