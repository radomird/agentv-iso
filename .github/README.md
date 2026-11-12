<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../branding/logo.svg">
    <img alt="AgenTV" src="../branding/logo-light.svg" width="520">
  </picture>
</p>

<p align="center">
  <b>The USB installer for AgenTV, the world's first open-source agentic TV OS.</b><br>
  Powered by <a href="https://omarchy.org">Omarchy</a>.
</p>

---

This is where the AgenTV USB stick comes from.

Put the ISO on a stick and start your box from it. The TV shows a code. Scan it with your phone, pick the disk and tap "Erase and install". That's the only question. The box installs AgenTV, restarts by itself, and your phone carries on with setup.

No phone to hand? Pick the disk with the keyboard and press Enter. Want every question Omarchy's own installer asks? Press Ctrl+C on the first screen.

It's for x86_64 PCs, and installing erases the disk you pick. [agentv-os's README](https://github.com/radomird/agentv-os#install-it) walks you through all of it, from the download to home.

## Getting the ISO

The stable ISO is on [the releases page](https://github.com/radomird/agentv-iso/releases), in the newest release. Its notes have the download link and the ISO's checksum. The file is named after its version, like `agentv-1.0.0-x86_64.iso`, and it's about 6.7 GB.

To check your download, grab its checksum and the checksum's signature too. They're at the ISO's address with `.sha256` and `.sha256.sig` on the end. Put them in the folder with the ISO and run this, with your ISO's version in place of `1.0.0`:

```
curl -LO https://raw.githubusercontent.com/radomird/agentv-pkgs/main/agentv-keyring/agentv.gpg
gpg --import agentv.gpg
gpg --verify agentv-1.0.0-x86_64.iso.sha256.sig agentv-1.0.0-x86_64.iso.sha256
sha256sum -c agentv-1.0.0-x86_64.iso.sha256
```

The first two lines fetch AgenTV's public key. You only need them once. `gpg --verify` should say "Good signature", from the key `B4D4 7D67 1A03 84BF 7516 4CF1 AD68 7DD5 C049 475F`. That tells you the checksum is mine. gpg also warns that you haven't told it to trust the key, and that's fine. `sha256sum -c` then tells you the ISO matches the checksum, and prints the ISO's name with `OK`. On a Mac it's `shasum -a 256 -c`.

There are two more ISOs, for trying what's next: the latest release candidate, like `agentv-1.0.0-rc1-x86_64.iso`, and last night's edge build, like `agentv-0.2.0.r422.g155320d30-x86_64.iso`. Edge's version is the one `agentv version` prints on a box you install from it.

The ISO is too big for GitHub's release files, so it lives on Cloudflare R2. Since the file's name changes with every version, three small files say which ISO is the newest of each: [stable.json](https://pub-18fa48b004b845838c98225b8955c7e6.r2.dev/iso/stable.json), [rc.json](https://pub-18fa48b004b845838c98225b8955c7e6.r2.dev/iso/rc.json) and [edge.json](https://pub-18fa48b004b845838c98225b8955c7e6.r2.dev/iso/edge.json). Those links don't change. Each has the ISO's file name, version, sha256 and address. Older ISOs aren't kept.

## How an ISO gets made

Every release tag builds the ISO here. Before you see it, it has to pass a test run in GitHub Actions: a VM installs it by itself, then boots what it installed into AgenTV's TV session. Then its checksum gets signed and the ISO goes to R2 (`bin/agentv-iso-publish`).

## Something went wrong?

[Tell me what happened](https://github.com/radomird/agentv-iso/issues/new/choose): how far it got, and what the TV showed when it stopped. For a security problem, please [tell me privately](https://github.com/radomird/agentv-iso/security/advisories/new) first.

## Support AgenTV

AgenTV is free and open source. If you'd like to help, you can [chip in through Stripe](https://buy.stripe.com/7sY4gzeMjdZs1oo7Wbgfu00) and pick the amount yourself. Thank you!

## Powered by Omarchy

This repo is a fork of [omacom/omarchy-iso](https://github.com/omacom/omarchy-iso), pinned to an upstream commit. I never edit Omarchy's files here. AgenTV only adds its own: the first screen, the build workflow, the settings that point the build at [`agentv-os`](https://github.com/radomird/agentv-os), and the installer logo. Omarchy's own README, with how to build and test an ISO yourself, is at [`../README.md`](../README.md).

Omarchy and its installer are MIT-licensed, and the [licence](../LICENSE) stays as it is. AgenTV's additions are copyright Radomir Drndarski and use the same licence. AgenTV isn't made or endorsed by the Omarchy project.

Some files here are about other machines Omarchy supports, such as an ARM laptop. They're Omarchy's. AgenTV is x86_64 only.
