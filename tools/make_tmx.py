#!/usr/bin/env python3
"""Read-only Tiled views of the port's graphics, per area (set), from the
assets written by tools/port_assets.py (run `make port` first).

usage: make_tmx.py ASSET_DIR ARCADE_BUILD OUT_DIR

Writes in OUT_DIR, for each area set N (0-7, area N+1):
  areaN_bg.png / areaN_bg.tsx   the 16x16 background tiles of the set, as the
                                port shows them (quantised palette block 0)
  areaN_bg.tmx                  the area's map strips (16 tiles wide) with
                                those tiles, bottom of the area at the bottom
  areaN_sprites.png / .tsx      the fixed sprite patterns of the set (SGT slots)
  areaN_sprites.tmx             the same patterns in a grid of 16 columns
and sprites_atlas.png/.tsx/.tmx: every measured sprite combo (code, flip, palette).
These are views: the port is built from the arcade data, not from these files
(they are written read-only).
"""
import sys, os, json, stat
from PIL import Image

A, ARC, OUT = (os.path.abspath(x) for x in sys.argv[1:4])
os.makedirs(OUT, exist_ok=True)
METATILES = 0x45C4
STRIPS = (0x4134, 0x4374)

def rgb(c):
    return tuple(v * 255 // 31 for v in c)

def palette_block(data, n):
    return [rgb(data[3 * (16 * n + i):3 * (16 * n + i) + 3]) for i in range(16)]

def pattern_px(buf, n):
    x0, y0 = 8 * (n % 32), 8 * (n // 32)
    rows = []
    for r in range(8):
        off = (y0 + r) * 128 + x0 // 2
        row = []
        for c in range(4):
            b = buf[off + c]
            row += [b >> 4, b & 15]
        rows.append(row)
    return rows

def cell_px(buf, k):
    x0, y0 = 16 * (k % 16), 16 * (k // 16)
    rows = []
    for r in range(16):
        off = (y0 + r) * 128 + x0 // 2
        row = []
        for c in range(8):
            b = buf[off + c]
            row += [b >> 4, b & 15]
        rows.append(row)
    return rows

def readonly(path):
    os.chmod(path, stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)

def write(path, text):
    if os.path.exists(path):
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    open(path, 'w').write(text)
    readonly(path)

def save_png(im, path):
    if os.path.exists(path):
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    im.save(path)
    readonly(path)

def tsx(name, png, w, h, count, cols):
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<tileset version="1.10" name="%s" tilewidth="16" tileheight="16" tilecount="%d" columns="%d">\n'
            ' <image source="%s" width="%d" height="%d"/>\n</tileset>\n' % (name, count, cols, png, w, h))

def tmx(tsxname, width, height, gids, props=''):
    rows = [','.join(str(g) for g in gids[r * width:(r + 1) * width]) for r in range(height)]
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<map version="1.10" orientation="orthogonal" renderorder="right-down" width="%d" height="%d" '
            'tilewidth="16" tileheight="16" infinite="0">\n%s'
            ' <tileset firstgid="1" source="%s"/>\n'
            ' <layer id="1" name="tiles" width="%d" height="%d" locked="1">\n  <data encoding="csv">\n%s\n  </data>\n </layer>\n</map>\n'
            % (width, height, props, tsxname, width, height, height and ',\n'.join(rows)))

def main():
    pal = open(os.path.join(A, 'palette.bin'), 'rb').read()
    rom = open(os.path.join(ARC, 'main_src.bin'), 'rb').read()
    for s in range(8):
        info = json.load(open(os.path.join(A, 'set%d_combos.json' % s)))
        combos = [tuple(c) for c in info['combos']]
        index = {c: i for i, c in enumerate(combos)}
        block0 = [rgb(pal[0:0])] if False else None
        spal = open(os.path.join(A, 'set%d_pal.bin' % s), 'rb').read()
        colours = [rgb(spal[3 * i:3 * i + 3]) for i in range(16)]
        bg = open(os.path.join(A, 'set%d_bg.bin' % s), 'rb').read()
        cols = 16
        rows = (len(combos) + cols - 1) // cols
        im = Image.new('RGB', (16 * cols, 16 * rows))
        for i in range(len(combos)):
            tile = Image.new('RGB', (16, 16))
            q = [pattern_px(bg, 4 * i + j) for j in range(4)]
            px = [q[0][r] + q[1][r] for r in range(8)] + [q[2][r] + q[3][r] for r in range(8)]
            tile.putdata([colours[v] for row in px for v in row])
            im.paste(tile, (16 * (i % cols), 16 * (i // cols)))
        base = 'area%d_bg' % s
        save_png(im, os.path.join(OUT, base + '.png'))
        write(os.path.join(OUT, base + '.tsx'), tsx(base, base + '.png', im.size[0], im.size[1], len(combos), cols))
        lo, hi = info['strips']
        strips = STRIPS[info['map']]
        gids = []
        for k in range(hi - 1, lo - 1, -1):          # top of the map first
            for r in range(4):
                for m in range(4):
                    mt = rom[strips + 4 * k + m]
                    for t in range(4):
                        a = METATILES + 32 * mt + 2 * (4 * r + t)
                        code = rom[a] | ((rom[a + 1] & 0xC0) << 2)
                        gids.append(index.get((code, rom[a + 1] & 0x3F), -1) + 1)
        props = ' <properties>\n  <property name="area" type="int" value="%d"/>\n  <property name="strips" value="%d-%d"/>\n  <property name="read_only" type="bool" value="true"/>\n </properties>\n' % (s + 1, lo, hi - 1)
        write(os.path.join(OUT, base + '.tmx'), tmx(base + '.tsx', 16, 4 * (hi - lo), gids, props))
        # fixed sprites of the set
        fixed = json.load(open(os.path.join(A, 'set%d_fixed.json' % s)))
        cells = open(os.path.join(A, 'set%d_spr.bin' % s), 'rb').read()
        sprite_rows = (len(fixed) + 15) // 16
        sim = Image.new('RGBA', (256, 16 * sprite_rows), (0, 0, 0, 0))
        for k, ent in enumerate(fixed):
            if ent is None:             # an unused slot
                continue
            code, flip, p = ent
            blk = palette_block(pal, 2 if p == 0 else 3)
            px = cell_px(cells, k)
            t = Image.new('RGBA', (16, 16))
            t.putdata([(0, 0, 0, 0) if v == 0 else blk[v] + (255,) for row in px for v in row])
            sim.paste(t, (16 * (k % 16), 16 * (k // 16)))
        base = 'area%d_sprites' % s
        save_png(sim, os.path.join(OUT, base + '.png'))
        write(os.path.join(OUT, base + '.tsx'), tsx(base, base + '.png', 256, 16 * sprite_rows, len(fixed), 16))
        write(os.path.join(OUT, base + '.tmx'), tmx(base + '.tsx', 16, sprite_rows, [k + 1 for k in range(len(fixed))],
              ' <properties>\n  <property name="area" type="int" value="%d"/>\n  <property name="slots" value="Fixed actor patterns for this area"/>\n  <property name="read_only" type="bool" value="true"/>\n </properties>\n' % (s + 1)))
    # whole atlas
    combos = json.load(open(os.path.join(A, 'spr_combos.json')))
    atlas = open(os.path.join(A, 'spr_atlas.bin'), 'rb').read()
    n = len(combos)
    rows = (n + 15) // 16
    aim = Image.new('RGBA', (256, 16 * rows), (0, 0, 0, 0))
    for k, (code, flip, p) in enumerate(combos):
        blk = palette_block(pal, 2 if p == 0 else 3)
        px = cell_px(atlas, k)
        t = Image.new('RGBA', (16, 16))
        t.putdata([(0, 0, 0, 0) if v == 0 else blk[v] + (255,) for row in px for v in row])
        aim.paste(t, (16 * (k % 16), 16 * (k // 16)))
    save_png(aim, os.path.join(OUT, 'sprites_atlas.png'))
    write(os.path.join(OUT, 'sprites_atlas.tsx'), tsx('sprites_atlas', 'sprites_atlas.png', 256, 16 * rows, n, 16))
    write(os.path.join(OUT, 'sprites_atlas.tmx'), tmx('sprites_atlas.tsx', 16, rows, [k + 1 if k < n else 0 for k in range(16 * rows)]))
    print('TMX views written to', OUT)

if __name__ == '__main__':
    main()
