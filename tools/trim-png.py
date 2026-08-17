#!/usr/bin/env python3
"""Trims the uniform border off a PNG, in place.

Headless Chrome only screenshots the window, so capturing a whole page means
giving it a window taller than the page and living with the empty strip
underneath. This removes that strip — and it does it by looking at the pixels
rather than by guessing a height, so nothing is ever cut off the bottom of the
content.

Pure standard library on purpose: this machine has no Pillow and no
ImageMagick, and a screenshot helper is not worth a dependency. Only the case
Chrome actually produces is handled — 8-bit RGB or RGBA, non-interlaced.
"""

import struct, sys, zlib


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG"
    pos, idat, meta = 8, bytearray(), None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            w, h, depth, colour, comp, filt, inter = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and colour in (2, 6) and inter == 0, "unsupported PNG"
            meta = (w, h, 3 if colour == 2 else 4)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length

    w, h, ch = meta
    raw = zlib.decompress(bytes(idat))
    stride = w * ch
    rows, prev = [], bytearray(stride)

    # Undo the per-row filters. Every PNG row carries the filter used on it.
    at = 0
    for _ in range(h):
        f = raw[at]; at += 1
        line = bytearray(raw[at:at + stride]); at += stride
        if f == 1:
            for i in range(ch, stride): line[i] = (line[i] + line[i - ch]) & 255
        elif f == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                left = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                b = prev[i]
                c = prev[i - ch] if i >= ch else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    return w, h, ch, rows


def write_png(path, w, h, ch, rows):
    raw = bytearray()
    for line in rows:
        raw.append(0)          # filter 0: the file is small either way
        raw += line
    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body
                + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff))
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2 if ch == 3 else 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


def trim(path, pad=0, tol=6):
    w, h, ch, rows = read_png(path)
    bg = rows[0][0:3]          # the top-left pixel is the page background

    def interesting(line):
        for i in range(0, len(line), ch):
            if (abs(line[i] - bg[0]) > tol or abs(line[i+1] - bg[1]) > tol
                    or abs(line[i+2] - bg[2]) > tol):
                return True
        return False

    keep = [y for y in range(h) if interesting(rows[y])]
    if not keep:
        return
    top, bottom = max(0, keep[0] - pad), min(h - 1, keep[-1] + pad)

    cols = []
    for x in range(w):
        o = x * ch
        for y in range(top, bottom + 1):
            line = rows[y]
            if (abs(line[o] - bg[0]) > tol or abs(line[o+1] - bg[1]) > tol
                    or abs(line[o+2] - bg[2]) > tol):
                cols.append(x); break
    left, right = (max(0, cols[0] - pad), min(w - 1, cols[-1] + pad)) if cols else (0, w - 1)

    out = [rows[y][left * ch:(right + 1) * ch] for y in range(top, bottom + 1)]
    write_png(path, right - left + 1, bottom - top + 1, ch, out)
    print(f"  {path}  {w}×{h} → {right-left+1}×{bottom-top+1}")


if __name__ == "__main__":
    pad = 0
    args = sys.argv[1:]
    if args and args[0].startswith("--pad="):
        pad = int(args.pop(0).split("=")[1])
    for f in args:
        trim(f, pad=pad)
