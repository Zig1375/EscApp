"""Writes a 32x32 amber square as a .ico, so the probes have an icon without a binary source file."""
import struct
import sys

size = 32
pixels = b"".join(struct.pack("<BBBB", 7, 75, 168, 255) for _ in range(size * size))  # BGRA amber
mask = b"\0" * (size * 4)  # 1-bit AND mask, rows padded to 4 bytes
header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, len(pixels) + len(mask), 0, 0, 0, 0)
image = header + pixels + mask
icon = struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(image), 22) + image
with open(sys.argv[1], "wb") as f:
    f.write(icon)
