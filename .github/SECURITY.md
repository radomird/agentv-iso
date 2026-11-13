# Security

Found a security problem in AgenTV? Please tell me privately first, so I can fix it before it's public.

## How to report it

Open this repo's [Security tab](https://github.com/radomird/agentv-iso/security) and press **Report a vulnerability**. Or go [straight to the form](https://github.com/radomird/agentv-iso/security/advisories/new). Only you and I see what you write there.

Please don't open a public issue for it.

## What to tell me

- What you found, and what someone could do with it.
- How to make it happen, step by step.
- The release you're on. It's in _Settings > System > About_ on the TV, or run `agentv version` on the box.
- Your box, if it matters.

Leave out keys, passwords and anything from your own accounts. I don't need them to fix it.

## What happens next

AgenTV is one person's project, so I won't promise a number of hours. I'll answer as soon as I can, tell you what I found, and tell you when the fix is out. If you'd like, I'll thank you in the release notes.

Fixes go into the next release and into edge. I don't patch older releases, so the way to get a fix is to update.

## What's in this repo

This is AgenTV's USB stick installer: the ISO, how it's built, and the first screen you see when a box boots from it, on the TV and on your phone. AgenTV itself is in [agentv-os](https://github.com/radomird/agentv-os), the packages your box updates from are in [agentv-pkgs](https://github.com/radomird/agentv-pkgs), and the apps are in [agentv-apps](https://github.com/radomird/agentv-apps).

Not sure which repo a problem belongs to? Report it here. I'll move it.

## AgenTV's or Omarchy's?

AgenTV is built on Omarchy. This policy covers what AgenTV adds, which is everything named `agentv`: the TV's home, TV setup, your phone as the remote, building your own apps, updates, the installer's first screen, the packages and the list of apps.

A problem in Omarchy itself goes to Omarchy, at [security@omarchy.org](mailto:security@omarchy.org). That's the Linux desktop, and Omarchy's own `omarchy` commands and packages. AgenTV isn't made or endorsed by the Omarchy project.

## Not a security problem?

[Open an issue](https://github.com/radomird/agentv-iso/issues/new/choose).
