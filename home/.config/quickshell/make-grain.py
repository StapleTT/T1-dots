#!/usr/bin/env python3
"""Writes the grain tiles: the same 256px noise for Quickshell's glass boxes and for kitty's background.

Each pixel is black or white with a random (gaussian) alpha. Quickshell's tile keeps full alpha and is faded by
boxGrain in shell.qml; kitty has no image opacity, so its strength is baked in. KITTY_STRENGTH was matched by eye
and pixel measurement to boxGrain 0.05 (kitty renders the image stronger than its alpha suggests).
Run after changing either value: python3 ~/.config/quickshell/make-grain.py
"""
import os, random, struct, zlib

SIZE = 256
KITTY_STRENGTH = 0.011


def tile(strength):
    random.seed(7)  # same pattern in both tiles
    rows = bytearray()
    for _ in range(SIZE):
        rows.append(0)
        for _ in range(SIZE):
            g = random.gauss(0, 1)
            v = 255 if g > 0 else 0
            rows += bytes((v, v, v, min(255, int(abs(g) * 110 * strength + 0.5))))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))


home = os.path.expanduser("~")
for path, strength in ((f"{home}/.config/quickshell/grain.png", 1.0), (f"{home}/.config/kitty/grain.png", KITTY_STRENGTH)):
    with open(path, "wb") as f:
        f.write(tile(strength))
    print("wrote", path)
