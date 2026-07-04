#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
from pathlib import Path


TEXTURES = (
    ("wizmet1_1", 64, 64, 40, 56),
    ("engineos_floor", 64, 64, 32, 48),
    ("engineos_water", 64, 64, 96, 112),
)


def miptex(name: str, width: int, height: int, a: int, b: int) -> bytes:
    sizes = [width * height, width * height // 4, width * height // 16, width * height // 64]
    header_size = 16 + 4 + 4 + 16
    offsets: list[int] = []
    cursor = header_size
    for size in sizes:
        offsets.append(cursor)
        cursor += size
    header = name.encode("ascii")[:15].ljust(16, b"\0")
    data = bytearray()
    data.extend(header)
    data.extend(struct.pack("<ii", width, height))
    data.extend(struct.pack("<iiii", *offsets))
    for level, size in enumerate(sizes):
        side = width >> level
        for index in range(size):
            x = index % side
            y = index // side
            data.append(a if ((x // 8) + (y // 8)) % 2 == 0 else b)
    return bytes(data)


def build_wad() -> bytes:
    lumps: list[tuple[str, bytes]] = [(name, miptex(name, w, h, a, b)) for name, w, h, a, b in TEXTURES]
    offset = 12
    directory = bytearray()
    body = bytearray()
    for name, payload in lumps:
        body.extend(payload)
        directory.extend(struct.pack("<iiibbxx16s", offset, len(payload), len(payload), 0x44, 0, name.encode("ascii")[:15].ljust(16, b"\0")))
        offset += len(payload)
    header = struct.pack("<4sii", b"WAD2", len(lumps), 12 + len(body))
    return header + body + directory


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(build_wad())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
