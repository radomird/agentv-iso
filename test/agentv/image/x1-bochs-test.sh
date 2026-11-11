#!/bin/bash
# TRIAL: the sleep check on QEMU's bochs display.
export T13_GPU="-device bochs-display"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/t13.2-sleep-test.sh"
