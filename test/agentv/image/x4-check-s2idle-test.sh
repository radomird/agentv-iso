#!/bin/bash
# TRIAL: the sleep check with the VM suspending to idle.
( sleep 1080; echo "TRIAL: out of time" >&2; pkill -TERM -P $$ ssh; kill -TERM $$ ) &
export T13_S2IDLE=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/t13.2-sleep-test.sh"
