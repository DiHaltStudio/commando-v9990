"""Graphics formats of the Commando board (from MAME capcom/commando.cpp).

Three tile sets, all planar with MAME's big-endian bit numbering (bit offset
0 = bit 7 of the byte) and plane 0 = most significant bit of the pixel:

  chars    vt01.5d (16 KB)           8x8, 2bpp, 16 bytes/char, 1024 chars
           row y = bytes 2y, 2y+1; plane 0 at bit offset 4, plane 1 at 0;
           pixels 0-3 from the first byte, 4-7 from the second
  tiles    vt11..vt16 (6 x 16 KB)    16x16, 3bpp, one plane per ROM pair:
           plane 0 = vt11+vt12, plane 1 = vt13+vt14, plane 2 = vt15+vt16;
           32 bytes/tile per plane: row y = byte y (pixels 0-7) and 16+y (8-15);
           1024 tiles
  sprites  vt05..vt10 (6 x 16 KB)    16x16, 4bpp, 64 bytes/sprite in each half:
           half A = vt05+vt06+vt07 (planes 2,3), half B = vt08+vt09+vt10 (planes 0,1);
           row y = bytes 4y..4y+3 (pixels 0-3, 4-7) and 32+4y.. (pixels 8-15);
           plane order per byte: high nibble bit = plane 0/2, low nibble = plane 1/3;
           768 sprites = 3 banks of 256

Palette PROMs vtb1/2/3 (red/green/blue, low nibble of 256 entries):
  colours 0-127 background (16 palettes x 8), 128-191 sprites (4 x 16),
  192-255 chars (16 x 4). Transparent pen: chars 3, sprites 15.
"""
import os

def bit(data, off):
    """Bit at big-endian bit offset off (0 = bit 7 of byte 0)."""
    return (data[off >> 3] >> (7 - (off & 7))) & 1

def setbit(data, off, v):
    if v:
        data[off >> 3] |= 1 << (7 - (off & 7))
    else:
        data[off >> 3] &= ~(1 << (7 - (off & 7))) & 0xFF

class Layout:
    def __init__(self, w, h, planes, planeoff, xoff, yoff, charsize):
        self.w, self.h, self.planes = w, h, planes
        self.planeoff, self.xoff, self.yoff, self.charsize = planeoff, xoff, yoff, charsize

    def decode(self, data, n):
        base = n * self.charsize
        rows = []
        for y in range(self.h):
            row = []
            for x in range(self.w):
                v = 0
                for p in range(self.planes):
                    v = v << 1 | bit(data, base + self.planeoff[p] + self.xoff[x] + self.yoff[y])
                row.append(v)
            rows.append(row)
        return rows

    def encode(self, data, n, rows):
        base = n * self.charsize
        for y in range(self.h):
            for x in range(self.w):
                v = rows[y][x]
                for p in range(self.planes):
                    setbit(data, base + self.planeoff[p] + self.xoff[x] + self.yoff[y],
                           (v >> (self.planes - 1 - p)) & 1)

def region_frac(size, num, den):
    return size * num // den

CHARS = Layout(8, 8, 2, [4, 0], [0, 1, 2, 3, 8, 9, 10, 11], [16 * i for i in range(8)], 16 * 8)

def tiles_layout(size):
    return Layout(16, 16, 3, [region_frac(size, 0, 3) * 8, region_frac(size, 1, 3) * 8, region_frac(size, 2, 3) * 8],
                  list(range(8)) + [16 * 8 + i for i in range(8)], [8 * i for i in range(16)], 32 * 8)

def sprites_layout(size):
    half = region_frac(size, 1, 2) * 8
    return Layout(16, 16, 4, [half + 4, half + 0, 4, 0],
                  [0, 1, 2, 3, 8, 9, 10, 11, 32 * 8 + 0, 32 * 8 + 1, 32 * 8 + 2, 32 * 8 + 3,
                   33 * 8 + 0, 33 * 8 + 1, 33 * 8 + 2, 33 * 8 + 3],
                  [16 * i for i in range(16)], 64 * 8)

CHAR_ROMS = ['vt01.5d']
TILE_ROMS = ['vt11.5a', 'vt12.6a', 'vt13.7a', 'vt14.8a', 'vt15.9a', 'vt16.10a']
SPRITE_ROMS = ['vt05.7e', 'vt06.8e', 'vt07.9e', 'vt08.7h', 'vt09.8h', 'vt10.9h']
PROM_ROMS = ['vtb1.1d', 'vtb2.2d', 'vtb3.3d', 'vtb4.1h', 'vtb5.6l', 'vtb6.6e']

def load_region(romdir, names):
    return bytearray(b''.join(open(os.path.join(romdir, n), 'rb').read() for n in names))

def palette(romdir):
    """256 (r, g, b) tuples, 0-255, from the three colour PROMs (4 bits each)."""
    r = open(os.path.join(romdir, 'vtb1.1d'), 'rb').read()
    g = open(os.path.join(romdir, 'vtb2.2d'), 'rb').read()
    b = open(os.path.join(romdir, 'vtb3.3d'), 'rb').read()
    return [((r[i] & 15) * 17, (g[i] & 15) * 17, (b[i] & 15) * 17) for i in range(256)]
