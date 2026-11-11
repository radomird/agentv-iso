#!/usr/bin/env python3
#
# A stand-in gamepad on the box, for the image checks: a uinput device with
# the sticks and buttons of an ordinary controller, so udev marks it as a
# joystick, the way it marks a real one. It runs as the person logged in on
# the screen, who may use uinput there (AgenTV's own udev rule).
#
#   gamepad.py <fifo>     makes the gamepad, then takes a line at a time
#                         from <fifo>:
#     guide <seconds>     holds the guide button for that long
#     a <seconds>         holds A for that long
#     quit                takes the gamepad away
#
# Standard library only.

import fcntl
import os
import struct
import sys
import time

# linux/input-event-codes.h
EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
BTN_SOUTH, BTN_EAST, BTN_NORTH, BTN_WEST = 0x130, 0x131, 0x133, 0x134
BTN_TL, BTN_TR, BTN_SELECT, BTN_START, BTN_MODE = 0x136, 0x137, 0x13A, 0x13B, 0x13C
BTN_THUMBL, BTN_THUMBR = 0x13D, 0x13E
ABS_X, ABS_Y, ABS_RX, ABS_RY, ABS_HAT0X, ABS_HAT0Y = 0x00, 0x01, 0x03, 0x04, 0x10, 0x11
BUS_USB = 0x03

# linux/uinput.h
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_ABSBIT = 0x40045567
UI_DEV_SETUP = 0x405C5503
UI_ABS_SETUP = 0x401C5504
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

NAME = b"AgenTV test gamepad"
BUTTONS = {"guide": BTN_MODE, "a": BTN_SOUTH}


def event(kind, code, value):
    now = time.time()
    return struct.pack("llHHi", int(now), int((now % 1) * 1_000_000), kind, code, value)


def create():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    for kind in (EV_KEY, EV_ABS):
        fcntl.ioctl(fd, UI_SET_EVBIT, kind)
    for code in (BTN_SOUTH, BTN_EAST, BTN_NORTH, BTN_WEST, BTN_TL, BTN_TR, BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBL, BTN_THUMBR):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    for code, low, high in ((ABS_X, -32768, 32767), (ABS_Y, -32768, 32767), (ABS_RX, -32768, 32767), (ABS_RY, -32768, 32767), (ABS_HAT0X, -1, 1), (ABS_HAT0Y, -1, 1)):
        fcntl.ioctl(fd, UI_SET_ABSBIT, code)
        # struct uinput_abs_setup: code, then struct input_absinfo.
        fcntl.ioctl(fd, UI_ABS_SETUP, struct.pack("HHiiiiii", code, 0, 0, low, high, 0, 0, 0))
    # struct uinput_setup: struct input_id, name[80], ff_effects_max.
    fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("HHHH80sI", BUS_USB, 0x1209, 0x0001, 1, NAME, 0))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def main(args):
    if len(args) != 1:
        print("usage: gamepad.py <fifo>", file=sys.stderr)
        return 2
    fifo = args[0]
    if not os.path.exists(fifo):
        os.mkfifo(fifo, 0o600)
    fd = create()
    print("the gamepad is there", flush=True)
    try:
        while True:
            with open(fifo) as lines:
                for line in lines:
                    words = line.split()
                    if words == ["quit"]:
                        return 0
                    if len(words) != 2 or words[0] not in BUTTONS:
                        print(f"not a line for the gamepad: {line.strip()}", flush=True)
                        continue
                    code = BUTTONS[words[0]]
                    os.write(fd, event(EV_KEY, code, 1) + event(EV_SYN, 0, 0))
                    print(f"{words[0]} down at {time.time():.3f}", flush=True)
                    time.sleep(float(words[1]))
                    os.write(fd, event(EV_KEY, code, 0) + event(EV_SYN, 0, 0))
                    print(f"{words[0]} up at {time.time():.3f}", flush=True)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
