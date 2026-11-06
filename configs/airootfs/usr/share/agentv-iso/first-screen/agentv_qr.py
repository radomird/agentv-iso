"""A QR code for the first screen to draw on the console.

The live system has no QR encoder of its own, and the first screen needs one
code: the setup hotspot's Wi-Fi details, or the box's address on the home
network. So this is a small one, written from the QR code standard
(ISO/IEC 18004): byte mode, error correction level M, versions 1 to 6
(up to 106 bytes, far more than either code needs).

    matrix("WIFI:T:WPA;S:AgenTV-1a2b;P:abcdefghjk;;")

gives the modules as rows of booleans, True for dark, without the quiet zone
around them. test/agentv/unit checks it against the standard's worked
example and reads codes back with zbarimg.
"""

from __future__ import annotations

# Error correction level M, by version: (codewords of error correction per
# block, blocks, data codewords per block). Versions 1 to 6 have one block
# size each.
LEVEL_M = {
    1: (10, 1, 16),
    2: (16, 1, 28),
    3: (26, 1, 44),
    4: (18, 2, 32),
    5: (24, 2, 43),
    6: (16, 4, 27),
}
ALIGNMENT = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34]}
FORMAT_LEVEL_M = 0b00


class TooLong(ValueError):
    pass


# --- Reed-Solomon over GF(256), x^8 + x^4 + x^3 + x^2 + 1 ----------------------


def gf_multiply(x: int, y: int) -> int:
    z = 0
    for i in reversed(range(8)):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def rs_divisor(degree: int) -> list[int]:
    result = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            result[j] = gf_multiply(result[j], root)
            if j + 1 < degree:
                result[j] ^= result[j + 1]
        root = gf_multiply(root, 0x02)
    return result


def rs_remainder(data: list[int], degree: int) -> list[int]:
    """The error correction codewords for one block of data."""
    divisor = rs_divisor(degree)
    result = [0] * degree
    for byte in data:
        factor = byte ^ result.pop(0)
        result.append(0)
        for i, coefficient in enumerate(divisor):
            result[i] ^= gf_multiply(coefficient, factor)
    return result


# --- The codewords ---------------------------------------------------------------


def pick_version(length: int) -> int:
    for version, (_, blocks, per_block) in LEVEL_M.items():
        # 4 bits of mode and 8 of length, then the bytes.
        if 12 + 8 * length <= blocks * per_block * 8:
            return version
    raise TooLong(f"{length} bytes is more than a version 6 code holds")


def codewords(text: str) -> tuple[int, list[int]]:
    """The version, and every codeword in the order it's placed."""
    data = text.encode("utf-8")
    version = pick_version(len(data))
    ec_per_block, blocks, per_block = LEVEL_M[version]
    capacity = blocks * per_block * 8

    bits: list[int] = []

    def put(value: int, count: int) -> None:
        bits.extend((value >> i) & 1 for i in reversed(range(count)))

    put(0b0100, 4)  # byte mode
    put(len(data), 8)
    for byte in data:
        put(byte, 8)
    put(0, min(4, capacity - len(bits)))
    put(0, -len(bits) % 8)
    pad = 0xEC
    while len(bits) < capacity:
        put(pad, 8)
        pad ^= 0xEC ^ 0x11
    words = [int("".join(map(str, bits[i : i + 8])), 2) for i in range(0, len(bits), 8)]

    split = [words[i * per_block : (i + 1) * per_block] for i in range(blocks)]
    ecc = [rs_remainder(block, ec_per_block) for block in split]
    placed = [block[i] for i in range(per_block) for block in split]
    placed += [block[i] for i in range(ec_per_block) for block in ecc]
    return version, placed


# --- The matrix ------------------------------------------------------------------


def format_bits(mask: int) -> int:
    data = FORMAT_LEVEL_M << 3 | mask
    remainder = data
    for _ in range(10):
        remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537)
    return (data << 10 | remainder) ^ 0x5412


def penalty(modules: list[list[bool]]) -> int:
    size = len(modules)
    score = 0
    lines = modules + [list(column) for column in zip(*modules)]
    finder = [True, False, True, True, True, False, True]
    for line in lines:
        run = 1
        for i in range(1, size + 1):
            if i < size and line[i] == line[i - 1]:
                run += 1
            else:
                if run >= 5:
                    score += 3 + run - 5
                run = 1
        for i in range(size - 6):
            if line[i : i + 7] == finder:
                before = line[max(0, i - 4) : i]
                after = line[i + 7 : i + 11]
                if (i < 4 or not any(before)) or (i + 11 > size or not any(after)):
                    score += 40
    for y in range(size - 1):
        for x in range(size - 1):
            if modules[y][x] == modules[y][x + 1] == modules[y + 1][x] == modules[y + 1][x + 1]:
                score += 3
    dark = sum(map(sum, modules))
    score += abs(dark * 20 - size * size * 10) // (size * size) * 10
    return score


MASKS = [
    lambda x, y: (x + y) % 2 == 0,
    lambda x, y: y % 2 == 0,
    lambda x, y: x % 3 == 0,
    lambda x, y: (x + y) % 3 == 0,
    lambda x, y: (x // 3 + y // 2) % 2 == 0,
    lambda x, y: x * y % 2 + x * y % 3 == 0,
    lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
    lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0,
]


def matrix(text: str) -> list[list[bool]]:
    version, words = codewords(text)
    size = 17 + 4 * version
    modules = [[False] * size for _ in range(size)]
    function = [[False] * size for _ in range(size)]

    def set_function(x: int, y: int, dark: bool) -> None:
        modules[y][x] = dark
        function[y][x] = True

    # Timing patterns, then the finders with their separators over them.
    for i in range(size):
        set_function(6, i, i % 2 == 0)
        set_function(i, 6, i % 2 == 0)
    for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                x, y = cx + dx, cy + dy
                if 0 <= x < size and 0 <= y < size:
                    distance = max(abs(dx), abs(dy))
                    set_function(x, y, distance not in (2, 4))
    positions = ALIGNMENT[version]
    for cy in positions:
        for cx in positions:
            if (cx, cy) in ((6, 6), (6, positions[-1]), (positions[-1], 6)):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    set_function(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)

    def draw_format(mask: int) -> None:
        bits = format_bits(mask)
        bit = [(bits >> i) & 1 == 1 for i in range(15)]
        for i in range(6):
            set_function(8, i, bit[i])
        set_function(8, 7, bit[6])
        set_function(8, 8, bit[7])
        set_function(7, 8, bit[8])
        for i in range(9, 15):
            set_function(14 - i, 8, bit[i])
        for i in range(8):
            set_function(size - 1 - i, 8, bit[i])
        for i in range(8, 15):
            set_function(8, size - 15 + i, bit[i])
        set_function(8, size - 8, True)

    draw_format(0)  # reserves the format areas

    # The data, two columns at a time from the right, up then down.
    i = 0
    total = len(words) * 8
    right = size - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vertical in range(size):
            for j in range(2):
                x = right - j
                upward = (right + 1) & 2 == 0
                y = size - 1 - vertical if upward else vertical
                if not function[y][x] and i < total:
                    modules[y][x] = (words[i >> 3] >> (7 - (i & 7))) & 1 == 1
                    i += 1
        right -= 2

    best = None
    for mask, rule in enumerate(MASKS):
        candidate = [row[:] for row in modules]
        for y in range(size):
            for x in range(size):
                if not function[y][x] and rule(x, y):
                    candidate[y][x] = not candidate[y][x]
        modules, saved = candidate, modules
        draw_format(mask)
        score = penalty(modules)
        if best is None or score < best[0]:
            best = (score, [row[:] for row in modules])
        modules = saved
    return best[1]


def wifi(ssid: str, password: str) -> str:
    """What a phone's camera reads to join a Wi-Fi network."""

    def escape(value: str) -> str:
        return "".join("\\" + c if c in '\\;,:"' else c for c in value)

    return f"WIFI:T:WPA;S:{escape(ssid)};P:{escape(password)};;"
