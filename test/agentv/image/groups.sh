# The image checks that need handling of their own. test/agentv/image/run
# reads these to order and place the checks on one runner, and
# test/agentv/image/shards to share them out across a run's jobs.
# shellcheck shell=bash disable=SC2034 # the lists are read by whoever sources this

# The slow ones first, so two lanes end near the same time: each restarts
# the box, waits out the idle minutes, or updates it.
# The ones that install from the USB stick's first screen, and wait for it,
# come first of all.
SLOW=(t1.1-first-screen t1.2-omarchy-installer t1.4-phone s4.5-pin idle s1.1-tv-session update-tv s3.6-music s4-hotspot home selftest)
# The checks that look at the ISO itself, which a run from the night's disk
# (AGENTV_TEST_NO_ISO, ci --from-disk) doesn't have.
NEEDS_ISO=(s0.4-branding t1.1-first-screen t1.2-omarchy-installer t1.4-phone)
# The checks that time the box against a bar (S1.3's 10 s). S1.3 was signed
# off on 2026-10-25 at 2 to 5 s, with one VM on the whole runner. Beside
# another VM, on half the CPUs, Omarchy's desktop back to the TV with the
# keys took 6 to 10 s every night from 2026-10-27, on the release and on edge
# alike, and failed at 10 s on 2026-11-01. So they run alone.
ALONE=(s1.3-switch)
