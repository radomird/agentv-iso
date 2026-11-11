#!/bin/bash
# TRIAL: the sleep check with virtio's GPU keeping its state across a sleep.
( sleep 1080; echo "TRIAL: out of time" >&2; pkill -TERM -P $$ ssh; kill -TERM $$ ) &
export T13_GPU="-device pcie-root-port,id=gpuport,chassis=9 -device virtio-vga,bus=gpuport,x-pcie-pm-no-soft-reset=on"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/t13.2-sleep-test.sh"
