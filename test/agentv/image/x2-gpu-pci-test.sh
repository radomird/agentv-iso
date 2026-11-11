#!/bin/bash
# TRIAL: the sleep check on virtio's GPU without its VGA side.
export T13_GPU="-device virtio-gpu-pci"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/t13.2-sleep-test.sh"
