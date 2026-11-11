#!/bin/bash
# TRIAL: the sleep check on QEMU's bochs display.
( sleep 840; echo "TRIAL: out of time" >&2; pkill -TERM -P $$ ssh; kill -TERM $$ ) &
export T13_GPU="-device bochs-display"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/t13.2-sleep-test.sh"
