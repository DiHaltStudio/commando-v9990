#!/usr/bin/env python3
"""Graphics and palettes for the V9990 port, from the arcade ROMs and the
MAME usage statistics.

usage: port_assets.py ARCADE_BUILD OUT_DIR

Reads graphics and PROMs from ARCADE_ROMS, map data from ARCADE_BUILD/main_src.bin,
and usage frequencies from assets/vramstats.json.

Everything is in screen orientation (the hardware picture rotated 90 degrees
counter-clockwise, flips applied first, as tools/map_export.py of the arcade
side does) and in V9990 P1 bitmap layout: pattern n (8x8) at x = 8*(n%32),
y = 8*(n/32); sprite cell k (16x16) at x = 16*(k%16), y = 16*(k/16); 4 bits
per pixel, left pixel in the high nibble, 128 bytes per bitmap line.

Outputs (OUT_DIR):
  palette.bin      64 colours x 3 bytes (R, G, B, 0-31): block 0 = set 0 background,
                   1 = text (global), 2 = sprite palette 0, 3 = sprite palette 1
  font.bin         plane A patterns from FONT_BASE: (char, text palette) combos
  font_direct.bin  32 KB: word at 2*(palette*1024 + char) = plane A pattern number
                   (the font also holds the plane A decorations: OVERLAY_SPRITES, 8 patterns each)
                   of (char, text palette), the transparent pattern if not in the font
  spr_atlas.bin    sprite cells, final colours: the (sprite, flip, palette) combos
  spr_idx.bin      768 words + lists of (flip | palette<<2, k lo, (k hi) | block<<4), $FF end
  spr_raw.bin      fallback: 768 sprites x 2 flips (none, flip Y) x 128 bytes,
                   pens shifted (p+1, 15 -> 0): final for palettes 0/1
  setN_bg.bin      plane B patterns of area set N (0-7): combo i -> patterns 4i..4i+3
  setN_bgidx.bin   1024 words + lists of (attr & $3F, base lo, base hi), $FF end
  setN_pal.bin     2560 bytes: blocks 0 and 1 of set N (32 x 3) at 0, the LUT page of each
                   decoration (a 32-byte segment of the font bitmap lines) at 96, the block 0
                   palette of the area-clear picture at 192, the plane A
                   palette zones (position word, variant; $FFFF end) at 256, the variants'
                   colours (block 1 entries 8-15, 24 bytes each) at 448, the decoration LUT
                   pages (byte of two pens -> byte of two block 1 indexes) at 1024 (8 at most)
  preview_setN.png the quantised background of the set, for checking
  assets.json      sizes and counts
"""
import sys, os, json, struct, collections
from PIL import Image

ARC = os.path.abspath(sys.argv[1])
OUT = os.path.abspath(sys.argv[2])
import gfxlib as G

ROMDIR = os.environ['ARCADE_ROMS']
FONT_BASE = 1024            # plane A patterns below 1024 are the sprite generator table
FONT_PALETTES = [8, 0, 5]   # every char in these text palettes; other combos from the statistics
# static decorations the port draws on plane A instead of sprites: (sprite number, arcade palette)
# bank 2 (512+): palm tree 10,11,2,3 + sway frames $10-$13, $18-$1B, rock 0,1 (palette 3); bunkers (palette 1); stone bridge
# 15,23,6,7,14 (palette 3); bridge 2: 4,5,12,13,22,30,31 (palette 2); bank 1 (256+): gorge
# walls / river banks 67,68,69,78 (palette 2). Both flips (none, flip Y = mirrored).
OVERLAY_SPRITES = [(512 + c, 3) for c in (10, 11, 2, 3, 0, 1, 15, 23, 6, 7, 14,
                                          0x10, 0x11, 0x12, 0x13, 0x18, 0x19, 0x1A, 0x1B)] + \
                  [(512 + c, 2) for c in (4, 5, 12, 13, 22, 30, 31)] + \
                  [(256 + c, 2) for c in (67, 68, 69, 78)] + \
                  [(512 + c, 1) for c in (0xA1, 0xA2, 0xA8, 0xA9, 0xB0, 0xB1, 0xB2, 0xB9,
                                          0xA4, 0xA5, 0xAB, 0xAC, 0xB3, 0xB4, 0xB5, 0xBC,   # bunker, damaged bunker
                                          0x56, 0x57, 0x5E)] + \
                  [(256 + c, 1) for c in (0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA8, 0xA9, 0xAA, 0xAB,
                                          0xAC, 0xAD, 0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xBB, 0xBD,    # area gate leaves (closed, half, open)
                                          0xAF, 0xB6, 0xAE, 0xA6, 0xA7)]                                # fortress gate: door, pillars
# decorations drawn as real sprites when the arcade draws them through its sprite entries (moving doors)
MOVING_DOORS = [(512 + 0x56, 1), (512 + 0x5E, 1), (256 + 0xAF, 1)]
# sprites drawn in front of plane A (the motorcycles ride on the bridges): bank 1 palette 1
# and the grenade / vehicle explosions (bank 1 palette 3, codes $80-$9B: over the rocks and trees)
FRONT_SPRITES = [(256 + c, 1) for c in range(0x60, 0x80)] + \
                [(256 + c, 3) for c in (0x80, 0x81, 0x82, 0x83, 0x88, 0x89, 0x8A, 0x8B,
                                        0x90, 0x91, 0x92, 0x93, 0x98, 0x99, 0x9A, 0x9B)]
# the helicopter's body (bank 2 palette 1, its three frames, both flips): fixed slots 0-55, the
# same in the sets of the pickup flight and of the drop-off (fortress areas 4 / 8, areas 5 / 1).
# With the text of the flight in slots 212-239 its pieces did not fit the cache (broken frames),
# and a load without blanking (flight -> next area) finds them in the same slots of the new set.
HELI_BODY = [(512 + c, f, 1) for c in (0xE0, 0xE1, 0xE8, 0xE9, 0xF0, 0xF1, 0xF8, 0xF9,
                                       0xE2, 0xE3, 0xE6, 0xEA, 0xEB, 0xF2, 0xF3, 0xFA, 0xFB,
                                       0xE4, 0xE5, 0xE7, 0xEC, 0xED, 0xEE, 0xEF, 0xF4, 0xF5, 0xFC, 0xFD)
             for f in (0, 2)]
# Rotor variants chosen from the arcade's eighteen blade lists at $A7A7-$A866.
# With flight text active only eight 4-way cache sets are available. These
# variants leave at most three blade variants per set at each altitude, so
# successive turns of the rotor reuse patterns even with a tree in that set.
HELI_ROTOR = [(512 + code, flip, 0) for code, flips in (
    (0xCA, (0, 3)), (0xCB, (1, 3)), (0xD0, (0, 2)), (0xD2, (0, 2)),
    (0xD3, (0, 2)), (0xD4, (0, 2)), (0xD8, (0, 2)), (0xD9, (0,)),
    (0xDA, (2,)), (0xDC, (0,)), (0xDD, (0, 2))) for flip in flips]
HELI_SETS = (0, 3, 4, 7)
# The bunker gunner (a real sprite at the bunker's list position, codes $A0/$A3/$AA/$AD of
# bank 2, palette 1, flip 0/2) goes GUN_DOWN lines lower: the bunker's plane A cells are on
# the 8-line rows and every bunker of the map lies 2 lines below its exact place (map y
# remainder); in the gap under the gunner the background's light roof edge showed (a white
# line on the gun slit). Fixed slots SPR_GUN0 .. SPR_FIX-1.
GUNNERS = [(512 + c, f, 1) for c in (0xA0, 0xA3, 0xAA, 0xAD) for f in (0, 2)]
GUN_DOWN = 2
SPR_FIX = 160               # fixed actor patterns, followed by the lower HUD band
SPR_GUN0 = SPR_FIX - len(GUNNERS)
MAP1_STRIPS, MAP2_STRIPS = 0x4134, 0x4374
# the pickup flight after area 4 scrolls past map 1's last strip: the arcade reads on into
# map 2's first strips (the lake of area 5, contiguous in the ROM), as far as strip 148
FLIGHT_NEXT = (5, 0)
N1, N2 = 144, 148
METATILES = 0x45C4
TAB_PORTRAIT = 0x09B5
TAB_STRINGS = 0x8276        # 43 pointers to (address, attribute, characters, '@')
TAB_STRINGS_N = 43
TAB_SMOKE = 0x0BA1          # 16 pointers to 4 text codes (2x2 smoke puff, palette 15)
TXT_TRANSPARENT = 3
TEX_BOOST = {4: 3.0}        # set -> extra weight per texture pixel (area 5's ground dither; elsewhere it cost other colours: area 4's wing, runway)
BG_MAX_ERR = 40             # block 0: no colour of BG_KEEP_SHARE of the pixels further than this (dist())
BG_KEEP_SHARE = 0.0025
TEX_MIN = 12               # colour distance (dist()) from which two neighbouring pixels count as texture
BG_WEIGHT_POW = 0.5         # block 0 k-means weight = pixel count ** this
TXT_COLOURS = 6              # plane A palette entries fixed for the text (2..7); 8 per set for the decorations
SPR_TRANSPARENT = 15
PAL1_MERGED_PEN, PAL1_MERGED_INTO = 3, 8   # sprite palette 1 pen 3 drawn with pen 8 (block 3 entry 4 = palette 3's light green)
PAL1_FREE_PEN = 10          # sprite palette 1 pen no sprite uses (block 3 entry 11 = palette 3's green)

def rgb5(c):
    return tuple(v >> 3 for v in c)

# ------------------------------------------------------------------ pens
def screen_pens(rows, flipx, flipy):
    """Board-orientation pens (list of rows) -> screen orientation (flips, then 90 CCW)."""
    n = len(rows)
    im = Image.new('L', (n, n))
    im.putdata([v for row in rows for v in row])
    if flipx:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    if flipy:
        im = im.transpose(Image.FLIP_TOP_BOTTOM)
    im = im.transpose(Image.ROTATE_90)
    d = list(im.getdata())
    return [d[y * n:(y + 1) * n] for y in range(n)]

def put_pattern(buf, n, px):
    """8x8 pixel values (list of 8 rows) -> pattern n of a plane bitmap."""
    x0, y0 = 8 * (n % 32), 8 * (n // 32)
    for r in range(8):
        off = (y0 + r) * 128 + x0 // 2
        row = px[r]
        for c in range(0, 8, 2):
            buf[off + c // 2] = (row[c] << 4) | row[c + 1]

def put_cell(buf, k, px):
    """16x16 pixel values -> sprite cell k of a bitmap (16 cells per row)."""
    x0, y0 = 16 * (k % 16), 16 * (k // 16)
    for r in range(16):
        off = (y0 + r) * 128 + x0 // 2
        row = px[r]
        for c in range(0, 16, 2):
            buf[off + c // 2] = (row[c] << 4) | row[c + 1]

def bitmap(nlines):
    return bytearray(nlines * 128)

# ------------------------------------------------------------------ colours
def dist(a, b):
    # weighted RGB distance plus a chroma term: a grey must not become a green of the same brightness
    return 2 * (a[0] - b[0]) ** 2 + 3 * (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2 + \
        2 * ((a[0] - a[1]) - (b[0] - b[1])) ** 2 + 2 * ((a[1] - a[2]) - (b[1] - b[2])) ** 2

def kmeans(points, k, fixed=(), medoid=None):
    """Weighted k-means over [(rgb, weight)]; returns k centroids (rgb tuples).
    fixed = centroids that must stay (e.g. black). medoid = {rgb: weight}: each final
    centroid is replaced by the member colour of its cluster with the least error under
    these weights (the dominant colour of a cluster stays exact instead of an average)."""
    pts = [(c, w) for c, w in points.items()] if isinstance(points, dict) else points
    uniq = {}
    for c, w in pts:
        uniq[c] = uniq.get(c, 0) + w
    pts = list(uniq.items())
    if len(pts) + len(fixed) <= k:
        cents = list(fixed) + [c for c, _ in sorted(pts, key=lambda p: -p[1]) if c not in fixed]
        return cents + [cents[0] if cents else (0, 0, 0)] * (k - len(cents))
    cents = list(fixed)
    # farthest-point seeding, weighted
    while len(cents) < k:
        best, bd = None, -1
        for c, w in pts:
            d = min(dist(c, x) for x in cents) if cents else 1
            d *= w ** 0.5
            if d > bd:
                best, bd = c, d
        cents.append(best)
    for _ in range(40):
        groups = [[] for _ in cents]
        for c, w in pts:
            i = min(range(len(cents)), key=lambda j: dist(c, cents[j]))
            groups[i].append((c, w))
        new = []
        for i, g in enumerate(groups):
            if i < len(fixed) or not g:
                new.append(cents[i]); continue
            tw = sum(w for _, w in g)
            new.append(tuple(int(round(sum(c[j] * w for c, w in g) / tw)) for j in range(3)))
        if new == cents:
            break
        cents = new
    if medoid:
        groups = [[] for _ in cents]
        for c, w in pts:
            groups[min(range(len(cents)), key=lambda j: dist(c, cents[j]))].append(c)
        for i, g in enumerate(groups):
            if i < len(fixed) or not g:
                continue
            cents[i] = min(g, key=lambda m: sum(medoid.get(c, 0) * dist(c, m) for c in g))
    return cents

def texture_loss(combos, skip, tile_pens, pal, block0):
    """Share of the (usage-weighted) adjacent pixel pairs that differ in the arcade tile
    (colour distance >= TEX_MIN) but get the same block 0 colour: the texture the
    quantisation flattened (the ground of area 5 came out plain)."""
    tot = lost = 0
    for (code, attr), w in combos.items():
        if (code, attr) in skip:
            continue
        p = attr & 15
        px = [[pal[8 * p + v] for v in row] for row in tile_pens[code]]
        ix = [[nearest(c, block0, 0) for c in row] for row in px]
        for y in range(16):
            for x in range(16):
                for dy, dx in ((0, 1), (1, 0)):
                    if y + dy < 16 and x + dx < 16:
                        tot += w
                        if ix[y][x] == ix[y + dy][x + dx] and px[y][x] != px[y + dy][x + dx] and \
                                dist(px[y][x], px[y + dy][x + dx]) >= TEX_MIN:
                            lost += w
    return lost / max(tot, 1)

def nearest(c, cents, lo=0):
    return min(range(lo, len(cents)), key=lambda j: dist(c, cents[j]))

# ------------------------------------------------------------------ decorations per set
TAB_BGOBJ = 0x4000          # structures: 76 x (x, code, pos b4-7 | mirrored<<3 | type, pos b8-15); map 2 from $40B0
TAB_MAP_EVENTS = 0x71AE     # map objects: (position LE with b14 = map, type, x, sprite address LE), end $FFFF
DECO_GROUPS = {             # map object type (or 'palm' / 'rock' structure) -> its decorations (sprite, palette)
    'palm': [(512 + c, 3) for c in (10, 11, 2, 3, 0x10, 0x11, 0x12, 0x13, 0x18, 0x19, 0x1A, 0x1B)],
    'rock': [(512, 3), (513, 3)],
    0x1A: [(512 + c, 3) for c in (15, 23, 6, 7, 14)],
    0x1B: [(512 + c, 2) for c in (4, 5, 12, 13, 22, 30, 31)],
    0x22: [(256 + c, 2) for c in (67, 68, 69, 78)],
    0x25: [(256 + c, 2) for c in (67, 68, 69, 78)],
    0x05: [(512 + c, 1) for c in (0xA1, 0xA2, 0xA8, 0xA9, 0xB0, 0xB1, 0xB2, 0xB9, 0xA4, 0xA5, 0xAB, 0xAC, 0xB3, 0xB4, 0xB5, 0xBC)],
    0x21: [(512 + c, 1) for c in (0x56, 0x57, 0x5E)],
    0x14: [(256 + c, 1) for c in (0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD,
                                  0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xBB, 0xBD)],
    0x28: [(256 + c, 1) for c in (0xAF, 0xB6, 0xAE, 0xA6, 0xA7)],
}

# groups drawn over background tiles of the same art (river bank, gorge walls): their colours
# are block 0's only, so the walls do not change colour when the sprites come (the river bank
# is drawn only once no bunker is alive: until then the walls are the plane B tiles alone)
DECO_BG_MATCH = (0x22, 0x25)
DECO_NOT_DRAWN = (0x22,)    # the river bank (mobj_riverbank patched to draw nothing): takes no colour slots

ZONE_BELOW = 272            # a map object at position E is on screen for scroll P in [E - ZONE_BELOW, E + ZONE_ABOVE]
ZONE_ABOVE = 80             # (created 0-255 px ahead, at the top edge; conservative for the tall ones)
ZONE_STEP = 8
MAX_VARIANTS = 16
MAX_ZONES = 63
DECO_SLOTS = 8              # block 1 entries 8-15: the decoration colours of the current zone
DECO_GOOD = 4.0             # a group takes no more slots once its mean pixel error is this low

def deco_objects(rom):
    """[(map, position, group key)] of the decorated structures and map objects."""
    objs = []
    r = TAB_BGOBJ
    while rom[r + 3] != 0xFF:
        pos = ((rom[r + 2] & 0xF0) | rom[r + 3] << 8) & 0x3FFF   # (map 2's positions carry bit 14: its
        objs.append((0 if r < 0x40B0 else 1, pos, 'rock' if rom[r + 2] & 7 else 'palm'))   # palms and rocks got no colours)
        r += 4
    r = TAB_MAP_EVENTS
    while rom[r] | rom[r + 1] << 8 != 0xFFFF:
        pos = rom[r] | rom[r + 1] << 8
        if rom[r + 2] in DECO_GROUPS and rom[r + 2] not in DECO_NOT_DRAWN:
            objs.append((pos >> 14, pos & 0x3FFF, rom[r + 2]))
        r += 6
    return objs

def deco_screens(objs, m, lo, hi):
    """The decoration groups on screen for each scroll position lo..hi (step ZONE_STEP) of map m.
    Groups that share sprites (river bank, gorge walls) are one group. Returns (canon:
    group key -> its group, [(P, frozenset of groups)])."""
    canon = {}
    for g in DECO_GROUPS:
        canon[g] = g
        for h in DECO_GROUPS:
            if h in canon and canon[h] == h and h != g and set(DECO_GROUPS[g]) & set(DECO_GROUPS[h]):
                canon[g] = h
                break
    seen = []
    for P in range(lo, hi, ZONE_STEP):
        seen.append((P, frozenset(canon[g] for mm, e, g in objs if mm == m and e - ZONE_BELOW <= P <= e + ZONE_ABOVE)))
    return canon, seen

# ------------------------------------------------------------------ inputs
def main():
    os.makedirs(OUT, exist_ok=True)
    pal = [rgb5(c) for c in G.palette(ROMDIR)]     # 256 x (r, g, b) 0-31
    chars = G.load_region(ROMDIR, G.CHAR_ROMS)
    tiles = G.load_region(ROMDIR, G.TILE_ROMS)
    sprites = G.load_region(ROMDIR, G.SPRITE_ROMS)
    char_pens = [G.CHARS.decode(chars, n) for n in range(1024)]
    tl = G.tiles_layout(len(tiles))
    tile_pens = [tl.decode(tiles, n) for n in range(1024)]
    sl = G.sprites_layout(len(sprites))
    spr_pens = [sl.decode(sprites, n) for n in range(768)]
    rom = open(os.path.join(ARC, 'main_src.bin'), 'rb').read()
    # Arcade text and sprite usage frequencies for the palette and cache builders.
    stats_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'vramstats.json')
    stats = json.load(open(stats_path)) if os.path.exists(stats_path) else {}
    info = {}

    # ------------------------------------------------------------ text block (global)
    txt_use = collections.Counter()      # (char, pal) -> weight
    for s in stats.values():
        for kk, v in s['txt'].items():
            c = int(kk); code = (c & 255) | (((c >> 8) & 0xC0) << 2); p = (c >> 8) & 15
            txt_use[(code, p)] += v
    pal_w = collections.Counter()
    for (code, p), v in txt_use.items():
        pal_w[p] += v
    for p in FONT_PALETTES:
        pal_w[p] += 1000
    colours = collections.Counter()
    for p in range(16):
        w = pal_w.get(p, 0) + 1
        for pen in range(4):
            if pen == TXT_TRANSPARENT:
                continue
            colours[pal[192 + 4 * p + pen]] += w
    # plane A palette (block 1): index 0 transparent, 1 opaque black (the margins), 2..1+TXT_COLOURS
    # the text colours (the font patterns are fixed in VRAM), the rest per set: colours of
    # the plane A decorations chosen among the set's block 0 (so they match the neighbouring
    # plane B tiles) and the decorations' own colours (see the set loop)
    colours.pop((0, 0, 0), None)         # black is index 1
    txt_cols = kmeans(colours, TXT_COLOURS)
    txt_fixed = [(0, 0, 0), (0, 0, 0)] + txt_cols
    txt_lut = {}
    for p in range(16):
        txt_lut[p] = [0 if pen == TXT_TRANSPARENT else nearest(pal[192 + 4 * p + pen], txt_fixed, 1) for pen in range(4)]
    spr_layout_tmp = G.sprites_layout(len(sprites))
    deco_pix = []                        # per decoration: Counter of pens
    for n, p in OVERLAY_SPRITES:
        deco_pix.append(collections.Counter(v for row in spr_layout_tmp.decode(sprites, n) for v in row if v != SPR_TRANSPARENT))

    # ------------------------------------------------------------ sprite blocks (global)
    spr_block = {}
    for b, p in ((2, 0), (3, 1)):
        spr_block[b] = [(0, 0, 0)] + [pal[128 + 16 * p + pen] for pen in range(15)]
    # sprite palette 1's pen 10 (yellow) is used by no sprite: block 3 gets the green of
    # palette 3's soldiers there (they were olive: palette 3 has no block of its own)
    spr_block[3][1 + PAL1_FREE_PEN] = pal[128 + 48 + 2]
    # and its pen 3 (12,10,6, little used) merges into pen 8 (14,10,6): its entry gets the
    # soldiers' light green (the CPU fallback remaps that index for palette 1 likewise)
    spr_block[3][1 + PAL1_MERGED_PEN] = pal[128 + 48 + 1]
    spr_lut, spr_blk = {}, {}
    for p in range(4):
        if p in (0, 1):
            spr_blk[p] = 2 + p
            spr_lut[p] = [0 if pen == SPR_TRANSPARENT else pen + 1 for pen in range(16)]
            if p == 1:
                spr_lut[p][PAL1_MERGED_PEN] = 1 + PAL1_MERGED_INTO
        else:
            best = None
            for b in (2, 3):
                err = sum(dist(pal[128 + 16 * p + pen], spr_block[b][nearest(pal[128 + 16 * p + pen], spr_block[b], 1)]) for pen in range(15))
                if best is None or err < best[0]:
                    best = (err, b)
            b = best[1]
            spr_blk[p] = b
            spr_lut[p] = [0 if pen == SPR_TRANSPARENT else nearest(pal[128 + 16 * p + pen], spr_block[b], 1) for pen in range(16)]

    # ------------------------------------------------------------ font
    font_combos = []
    for p in FONT_PALETTES:
        for code in range(1024):
            font_combos.append((code, p))
    seen = set(font_combos)
    for (code, p), v in sorted(txt_use.items(), key=lambda kv: -kv[1]):
        if (code, p) not in seen:
            font_combos.append((code, p)); seen.add((code, p))
    # every character of the arcade's strings in its palette (tab_strings: address word,
    # attribute (b0-3 palette, b6 = code + $100), characters, '@' end): RANKING BEST 7,
    # INSERT COIN, 2UP... were missing (palettes outside FONT_PALETTES, unseen by MAME runs)
    for i in range(TAB_STRINGS_N):
        ptr = rom[TAB_STRINGS + 2 * i] | rom[TAB_STRINGS + 2 * i + 1] << 8
        if not ptr:
            continue
        attr = rom[ptr + 2]
        q = ptr + 3
        while rom[q] != 0x40 and q < ptr + 64:
            key = (rom[q] | ((attr >> 6) & 1) << 8, attr & 15)
            if key not in seen:
                font_combos.append(key); seen.add(key)
            q += 1
    # Soldier title: the blinking prompt and the studio credit use different palettes.
    for string, palette in [(b'PRESS FIRE TO START', 1), (b'DIHALT 2026', 5)]:
        for code in string:
            if (code, palette) not in seen:
                font_combos.append((code, palette)); seen.add((code, palette))
    # TIMER uses the low digit tiles. rank_name_symbol draws the saved heart in
    # palette 1, even though the same tile uses palette 0 in the entry grid.
    for code in (*range(10), 0x5C):
        if (code, 1) not in seen:
            font_combos.append((code, 1)); seen.add((code, 1))
    # the smoke puffs of the area-clear picture: text tiles with palette 15 (tab_smoke_frames)
    for i in range(16):
        ptr = rom[TAB_SMOKE + 2 * i] | rom[TAB_SMOKE + 2 * i + 1] << 8
        for code in rom[ptr:ptr + 4]:
            if (code, 15) not in seen:
                font_combos.append((code, 15)); seen.add((code, 15))
    nfont = len(font_combos)
    pat_blank, pat_black = FONT_BASE + nfont, FONT_BASE + nfont + 1   # transparent / opaque black
    ovl_base = FONT_BASE + ((nfont + 2 + 31) // 32) * 32              # overlay patterns: 4 per (sprite, flip Y), from a row of 32
    novl = 2 * len(OVERLAY_SPRITES)
    deco_rows = (4 * novl + 31) // 32
    font_lines = ((ovl_base - FONT_BASE) // 32 + deco_rows) * 8
    font = bitmap(font_lines)
    font_n = {}
    for i, (code, p) in enumerate(font_combos):
        n = FONT_BASE + i
        font_n[(code, p)] = n
        px = screen_pens(char_pens[code], False, False)
        put_pattern(font, n - FONT_BASE, [[txt_lut[p][v] for v in row] for row in px])
    put_pattern(font, pat_blank - FONT_BASE, [[0] * 8 for _ in range(8)])
    put_pattern(font, pat_black - FONT_BASE, [[1] * 8 for _ in range(8)])
    # overlay patterns: decoration k, flip Y f -> 4 patterns (TL, TR, BL, BR) from ovl_base + 4 * (2k + f),
    # stored as raw arcade pens (0-15): load_set converts them through the set's LUT (a page per
    # sprite palette, byte -> byte) into the plane A patterns. One decoration = 8 patterns = 32 bytes
    # of a bitmap line (a "segment"): deco_seg.bin gives the LUT page (0-2) of each segment.
    k = 0
    for n, p in OVERLAY_SPRITES:
        for flipy in (0, 1):
            px = screen_pens(spr_pens[n], False, bool(flipy))
            quads = [[r[:8] for r in px[:8]], [r[8:] for r in px[:8]], [r[:8] for r in px[8:]], [r[8:] for r in px[8:]]]
            base = ovl_base + 4 * k
            for q in range(4):
                put_pattern(font, base + q - FONT_BASE, quads[q])
            k += 1
    open(os.path.join(OUT, 'font.bin'), 'wb').write(font)
    # direct table: word at 2*(palette*1024 + char) = plane A pattern (PATA_BLANK if unknown)
    direct = bytearray()
    for p in range(16):
        for code in range(1024):
            n = font_n.get((code, p), pat_blank)
            direct += bytes([n & 255, n >> 8])
    open(os.path.join(OUT, 'font_direct.bin'), 'wb').write(direct)
    # bank 2 palette 3 sprite code -> decoration k ($FF none): the map structures hook (palm trees, rocks)
    k2p3 = bytearray(b'\xFF' * 256)
    for k, (n, p) in enumerate(OVERLAY_SPRITES):
        if n >= 512 and p == 3:
            k2p3[n - 512] = k
    open(os.path.join(OUT, 'ovl_k2p3.bin'), 'wb').write(k2p3)
    # decorations the arcade also draws as plain sprites while they move (the doors of the
    # dugouts and of the fortress gate slide by the pixel): through the sprite entries they
    # stay real sprites (their static lists, door closed, still go to plane A)
    deco_spr = bytearray(len(OVERLAY_SPRITES))
    for k, (n, p) in enumerate(OVERLAY_SPRITES):
        if (n, p) in MOVING_DOORS:
            deco_spr[k] = 1
    open(os.path.join(OUT, 'deco_sprite.bin'), 'wb').write(deco_spr)
    info['font'] = {'patterns': nfont, 'bytes': len(font), 'base': FONT_BASE, 'blank': pat_blank, 'black': pat_black,
                    'ovl_base': ovl_base, 'overlays': len(OVERLAY_SPRITES), 'deco_rows': deco_rows}

    # ------------------------------------------------------------ sprite atlas
    spr_use = collections.Counter()
    for s in stats.values():
        for kk, v in s['spr'].items():
            c = int(kk); code = c & 1023; a = c >> 10; flip = (a >> 2) & 3; p = (a >> 4) & 3
            spr_use[(code, flip, p)] += v
    # the title screen soldier (anim_title_player: codes $20-$22, attribute 0)
    for code in (0x20, 0x21, 0x22):
        spr_use[(code, 0, 0)] += 1
    # combos met by the port itself (tools/openmsx/seen.tcl runs, merged into assets/sprites_seen.json)
    seen_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'sprites_seen.json')
    if os.path.exists(seen_path):
        for code, flip, p in json.load(open(seen_path)):
            spr_use[(code, flip, p)] += 1
    # the helicopter (title and start of the game): bank 2 $C0-$DF, palette 0, every flip
    for code in range(0x2C0, 0x2E0):
        for flip in range(4):
            spr_use[(code, flip, 0)] += 1
    spr_combos = [k for k, _ in sorted(spr_use.items(), key=lambda kv: -kv[1])]
    natlas = len(spr_combos)
    atlas_lines = ((natlas + 15) // 16) * 16
    atlas = bitmap(atlas_lines)
    for k, (code, flip, p) in enumerate(spr_combos):
        px = screen_pens(spr_pens[code], bool(flip & 1), bool(flip & 2))
        put_cell(atlas, k, [[spr_lut[p][v] for v in row] for row in px])
    open(os.path.join(OUT, 'spr_atlas.bin'), 'wb').write(atlas)
    open(os.path.join(OUT, 'spr_idx.bin'), 'wb').write(index_table(
        spr_combos, 768, lambda key, k: bytes([key[1] | (key[2] << 2), k & 255, (k >> 8) | (spr_blk[key[2]] << 4)])))
    info['sprites'] = {'cells': natlas, 'bytes': len(atlas), 'blocks': spr_blk, 'fixed': SPR_FIX,
                       'gun0': SPR_GUN0, 'gun_down': GUN_DOWN, 'heli': len(HELI_BODY) + len(HELI_ROTOR)}
    # fallback raw atlas: 768 x 2 flips (none, flip Y = attribute b3), shifted pens
    raw = bytearray()
    for code in range(768):
        for flip in (0, 2):
            px = screen_pens(spr_pens[code], False, bool(flip & 2))
            for row in px:
                for c in range(0, 16, 2):
                    a = 0 if row[c] == 15 else row[c] + 1
                    b = 0 if row[c + 1] == 15 else row[c + 1] + 1
                    raw.append((a << 4) | b)
    open(os.path.join(OUT, 'spr_raw.bin'), 'wb').write(raw)

    # ------------------------------------------------------------ per-set fixed sprites
    FIX = SPR_FIX
    blank_sprites = [n for n in range(768) if all(v == SPR_TRANSPARENT for row in spr_pens[n] for v in row)]
    # (sprite, palette) combos that never take a fixed slot: decorations (plane A) and front sprites (dynamic)
    special = {(n, p): FIX + k for k, (n, p) in enumerate(OVERLAY_SPRITES)}
    special.update({(n, p): 0xFE for n, p in FRONT_SPRITES})
    glob_rank = [k for k, _ in sorted(spr_use.items(), key=lambda kv: -kv[1]) if (k[0], k[2]) not in special]
    for sset in range(8):
        use = collections.Counter()
        key = str(sset)
        if key in stats:
            for kk, v in stats[key]['spr'].items():
                c = int(kk); code = c & 1023; a = c >> 10
                use[(code, (a >> 2) & 3, (a >> 4) & 3)] += v
        if 'attract' in stats:
            for kk, v in stats['attract']['spr'].items():
                c = int(kk); code = c & 1023; a = c >> 10
                use[(code, (a >> 2) & 3, (a >> 4) & 3)] += v
        ranked = [k for k, _ in sorted(use.items(), key=lambda kv: -kv[1]) if (k[0], k[2]) not in special]
        if sset in HELI_SETS:
            flight = HELI_BODY + HELI_ROTOR
            ranked = flight + [k for k in ranked if k not in flight]
        for k in glob_rank:                      # fill up with the global ranking
            if len(ranked) >= FIX:
                break
            if k not in use:
                ranked.append(k)
        # at most 2 variants per sprite number in the direct table; the bunker gunners take
        # the last slots (SPR_GUN0..: drawn GUN_DOWN lines lower, see GUNNERS)
        fixed, nvar = [], collections.Counter()
        for k in ranked:
            if len(fixed) >= SPR_GUN0:
                break
            if k not in GUNNERS and nvar[k[0]] < 2:
                fixed.append(k); nvar[k[0]] += 1
        fixed += [None] * (SPR_GUN0 - len(fixed)) + GUNNERS     # (None: an unused slot)
        cells = bitmap((SPR_FIX // 16) * 16)
        smap = bytearray(b'\xFF' * (768 * 4))
        for slot, k in enumerate(fixed):
            if k is None:
                continue
            code, flip, p = k
            px = screen_pens(spr_pens[code], bool(flip & 1), bool(flip & 2))
            put_cell(cells, slot, [[spr_lut[p][v] for v in row] for row in px])
            o = 4 * code
            if smap[o] == 0xFF:
                smap[o] = flip | (p << 2); smap[o + 1] = slot
            else:
                smap[o + 2] = flip | (p << 2); smap[o + 3] = slot
        # direct table: byte at ((attr >> 2) & $3F) * 256 + code = fixed slot, $FF = not fixed
        # SPR_FIX + k = decoration k (plane A cells, flip Y from the attribute), $FD = not drawn,
        # $FE = dynamic in front of plane A
        direct = bytearray(b'\xFF' * 16384)
        for slot, k in enumerate(fixed):
            if k is None:
                continue
            code, flip, p = k
            bank, c8 = code >> 8, code & 255
            attr = (bank << 6) | (p << 4) | (flip << 2)
            direct[((attr >> 2) & 0x3F) * 256 + c8] = slot
        for (code, p), v in special.items():
            for flip in (0, 2):
                attr = ((code >> 8) << 6) | (p << 4) | (flip << 2)
                direct[((attr >> 2) & 0x3F) * 256 + (code & 255)] = v
        # $FD = not drawn: bank 3 (no graphics) and the fully transparent sprites (the
        # arcade draws code $FF and a few others as empty sprites)
        for row in range(0x30, 0x40):
            direct[row * 256:row * 256 + 256] = b'\xFD' * 256
        for code in blank_sprites:
            for row in range((code >> 8) * 16, (code >> 8) * 16 + 16):
                direct[row * 256 + (code & 255)] = 0xFD
        open(os.path.join(OUT, 'set%d_sprdirect.bin' % sset), 'wb').write(direct)
        if sset in HELI_SETS:
            assert fixed[:len(flight)] == flight, 'set %d: helicopter slots differ' % sset
        json.dump([list(k) if k else None for k in fixed], open(os.path.join(OUT, 'set%d_fixed.json' % sset), 'w'))
        open(os.path.join(OUT, 'set%d_spr.bin' % sset), 'wb').write(cells)
        open(os.path.join(OUT, 'set%d_sprmap.bin' % sset), 'wb').write(smap)

    # ------------------------------------------------------------ area sets
    def w16(a):
        return rom[a] | rom[a + 1] << 8
    portrait = {}
    for s in range(8):
        p = w16(TAB_PORTRAIT + 2 * s)
        portrait[s] = [(rom[p + 2 * i] | ((rom[p + 2 * i + 1] & 0xC0) << 2), rom[p + 2 * i + 1] & 0x3F) for i in range(12)]
    set_pal0 = None
    set_ranges = {}
    for s in range(8):
        nstrips = N1 if s < 4 else N2
        lo, hi = max(0, (s & 3) * 32 - 1), min(nstrips, (s & 3) * 32 + 32 + 6)
        set_ranges[s] = (s >> 2, lo, nstrips + FLIGHT_NEXT[s >> 2] if s & 3 == 3 else hi)
    objs = deco_objects(rom)
    for s in range(8):
        mapn = s >> 2
        base_strip = (s & 3) * 32
        nstrips = N1 if mapn == 0 else N2
        strips_addr = MAP1_STRIPS if mapn == 0 else MAP2_STRIPS
        lo = max(0, base_strip - 1)
        hi = min(nstrips, base_strip + 32 + 6)
        if s & 3 == 3:
            hi = nstrips + FLIGHT_NEXT[mapn]  # the extra strips of the lap end flight
        combos = collections.Counter()
        for k in range(lo, hi):
            for m in range(4):
                mt = rom[strips_addr + 4 * k + m]
                for i in range(16):
                    a = METATILES + 32 * mt + 2 * i
                    code = rom[a] | ((rom[a + 1] & 0xC0) << 2)
                    combos[(code, rom[a + 1] & 0x3F)] += 1
        combos[(0xF8, 0)] += 50                  # the blank tile of bg_clear
        if 'attract' in stats:                   # title screen pictures (any set can be loaded then)
            for kk, v in stats['attract']['bg'].items():
                c = int(kk); combos[((c & 255) | (((c >> 8) & 0xC0) << 2), (c >> 8) & 0x3F)] += 1
        key = str(s)
        if key in stats:
            for kk, v in stats[key]['bg'].items():
                c = int(kk); code = (c & 255) | (((c >> 8) & 0xC0) << 2); attr = (c >> 8) & 0x3F
                combos[(code, attr)] += 1
        # the area-clear picture's tiles (shown alone on a blank plane B) have a palette of their
        # own: present writes it to block 0 while the picture is up (IO_SCROLLY_HI = 1)
        portrait_only = set(k for k in portrait[s] if k not in combos)
        for code, attr in portrait[s]:
            combos[(code, attr)] += 5
        pcol = collections.Counter()
        for code, attr in portrait_only:
            for row in tile_pens[code]:
                for v in row:
                    pcol[pal[8 * (attr & 15) + v]] += 1
        pcol.pop((0, 0, 0), None)
        portrait_pal = kmeans(collections.Counter({c: w ** BG_WEIGHT_POW for c, w in pcol.items()}), 16,
                              fixed=[(0, 0, 0)], medoid=pcol) if pcol else [(0, 0, 0)] * 16
        port_lut = {p: [nearest(pal[8 * p + pen], portrait_pal, 0) for pen in range(8)] for p in range(16)}
        # block 0: weighted colours of the combos (pens of the palette, by pixel count)
        colours = collections.Counter()
        for (code, attr), w in combos.items():
            if (code, attr) in portrait_only:
                continue
            p = attr & 15
            cnt = collections.Counter(v for row in tile_pens[code] for v in row)
            for pen, n in cnt.items():
                colours[pal[8 * p + pen]] += w * n
        # weights damped: rare colours (the grey wall in a green area) keep a representative
        raw = colours
        # the colours of texture (neighbouring pixels of clearly different colours) count TEX_BOOST
        # times more per such pixel: the ground dither of area 5 used to be merged into one colour
        tex = collections.Counter()
        for (code, attr), w in combos.items():
            if (code, attr) in portrait_only:
                continue
            q = [[pal[8 * (attr & 15) + v] for v in row] for row in tile_pens[code]]
            for y in range(16):
                for x in range(16):
                    for dy, dx in ((0, 1), (1, 0)):
                        if y + dy < 16 and x + dx < 16 and q[y][x] != q[y + dy][x + dx] and \
                                dist(q[y][x], q[y + dy][x + dx]) >= TEX_MIN:
                            tex[q[y][x]] += w
                            tex[q[y + dy][x + dx]] += w
        boost = float(os.environ['TEX_BOOST']) if 'TEX_BOOST' in os.environ else TEX_BOOST.get(s, 0.0)
        boosted = collections.Counter({c: w + boost * tex[c] for c, w in raw.items()})
        colours = collections.Counter({c: w ** BG_WEIGHT_POW for c, w in boosted.items()})
        block0 = kmeans(colours, 16, fixed=[(0, 0, 0)], medoid=raw)
        # repair: a colour of at least BG_KEEP_SHARE of the pixels further than BG_MAX_ERR from every
        # entry takes the entry whose loss costs least (the texture weight gave the fortress's dark
        # grey of area 4 a blue)
        tot = sum(raw.values())
        for _ in range(6):
            bad = [(min(dist(c, x) for x in block0), c) for c, w in raw.items() if w >= tot * BG_KEEP_SHARE]
            bad = [b for b in bad if b[0] > BG_MAX_ERR]
            if not bad:
                break
            c_bad = max(bad)[1]
            def total(cents):
                return sum(w * min(dist(c, x) for x in cents) for c, w in colours.items())
            best_i = min(range(1, 16), key=lambda i: total(block0[:i] + [c_bad] + block0[i + 1:]))
            block0 = block0[:best_i] + [c_bad] + block0[best_i + 1:]
        if os.environ.get('TEX_DEBUG'):
            cerr = sum(w * min(dist(c, x) for x in block0) for c, w in raw.items()) / sum(raw.values())
            print('set', s, 'texture loss %.4f colour err %.2f' % (texture_loss(combos, portrait_only, tile_pens, pal, block0), cerr),
                  'maxerr %.0f' % max(min(dist(c, x) for x in block0) for c, w in raw.items() if w > sum(raw.values()) * 0.002),
                  sorted(((round(min(dist(c, x) for x in block0)), c, round(1000 * w / sum(raw.values()))) for c, w in raw.items()
                          if w > sum(raw.values()) * 0.002), reverse=True)[:3])
        bg_lut = {}
        for p in range(16):
            bg_lut[p] = [nearest(pal[8 * p + pen], block0, 0) for pen in range(8)]
        combo_list = [k for k, _ in sorted(combos.items(), key=lambda kv: -kv[1])]
        nb = len(combo_list)
        lines = ((4 * nb + 31) // 32) * 8
        bg = bitmap(lines)
        for i, (code, attr) in enumerate(combo_list):
            p = attr & 15
            px = screen_pens(tile_pens[code], bool(attr & 0x10), bool(attr & 0x20))
            lut = port_lut if (code, attr) in portrait_only else bg_lut
            px = [[lut[p][v] for v in row] for row in px]
            quads = [[r[:8] for r in px[:8]], [r[8:] for r in px[:8]], [r[:8] for r in px[8:]], [r[8:] for r in px[8:]]]
            for q in range(4):
                put_pattern(bg, 4 * i + q, quads[q])
        open(os.path.join(OUT, 'set%d_bg.bin' % s), 'wb').write(bg)
        json.dump({'combos': [list(k) for k in combo_list], 'strips': [lo, hi], 'map': mapn},
                  open(os.path.join(OUT, 'set%d_combos.json' % s), 'w'))
        open(os.path.join(OUT, 'set%d_bgidx.bin' % s), 'wb').write(index_table(
            combo_list, 1024, lambda key, i: bytes([key[1], (4 * i) & 255, (4 * i) >> 8])))
        # block 1: the fixed text colours (indexes 1-7) + 8 slots (8-15) for the decorations.
        # Each decoration group of the set takes the slots it needs (heaviest group first,
        # greedy weighted error, candidates = the block 0 colours and its own colours, an own
        # colour near a block 0 colour snaps to it); groups seen on the same screen (zone)
        # must not take the same slot with different colours, groups never on the same
        # screen may. A zone = a set of groups on screen; its variant = the slot colours of
        # its groups, switched by the map position (present_zone). A group's LUT page maps
        # its pens to the text colours and its slots.
        m, zlo, zhi = set_ranges[s]
        canon, seen = deco_screens(objs, m, 64 * zlo, 64 * zhi)
        screens = sorted(set(z for P, z in seen if z), key=lambda z: sorted(map(str, z)))
        present_g = set().union(*screens) if screens else set()
        gpix = {}
        for g in present_g:
            cnt = collections.Counter()
            for k, (n, p) in enumerate(OVERLAY_SPRITES):
                if (n, p) in DECO_GROUPS[g]:
                    for pen, c in deco_pix[k].items():
                        cnt[pal[128 + 16 * p + pen]] += c
            gpix[g] = cnt
        def gerr(dw, cols):
            return sum(w * min(dist(c, x) for x in cols) for c, w in dw.items())
        groups = sorted(present_g, key=lambda g: (-sum(gpix[g].values()), str(g)))
        gzs = {g: [z for z in screens if g in z] for g in groups}
        bg_match = set(canon[g] for g in DECO_BG_MATCH)
        gcands = {g: list(dict.fromkeys(block0[1:] + ([] if g in bg_match else list(gpix[g].keys()))))
                  for g in groups}
        def g_use(slots, g):
            """use: slot -> colour set in every zone of g (its LUT may point there); free: slots
            unset in all its zones; part: slot -> the one colour set in some of its zones only
            (the others would show another group's colour or black: usable once completed)."""
            use, free, part = {}, [], {}
            for i in range(DECO_SLOTS):
                vals = [slots[z][i] for z in gzs[g]]
                cols = set(vals) - {None}
                if not cols:
                    free.append(i)
                elif len(cols) == 1:
                    (part if None in vals else use)[i] = cols.pop()
            return use, free, part
        def g_err(slots, g):
            dw = gpix[g]
            return gerr(dw, list(txt_fixed[1:]) + list(g_use(slots, g)[0].values())) / sum(dw.values())
        def give(slots, g, col, i, have):
            if col not in block0 and all(slots[z][i] is None for z in gzs[g]):
                near = min(block0[1:], key=lambda x: dist(col, x))
                if dist(col, near) <= 12 and near not in have:
                    col = near
            for z in gzs[g]:
                slots[z][i] = col
        def best_colour(slots, g):
            """(gain, colour, slot, have) of the best colour for a free slot of g, or None."""
            use, free, part = g_use(slots, g)
            if not free and not part:
                return None
            dw = gpix[g]
            have = list(txt_fixed[1:]) + list(use.values())
            cur = gerr(dw, have)
            if cur / sum(dw.values()) <= DECO_GOOD:
                return None
            best = None
            opts = [(c, i) for i, c in part.items() if g not in bg_match or c in block0] + \
                   ([(c, free[0]) for c in gcands[g]] if free else [])
            for col, i in opts:
                if min(dist(col, x) for x in have) <= 12:
                    continue
                gain = cur - gerr(dw, have + [col])
                if gain > 0 and (best is None or gain > best[0]):
                    best = (gain, col, i, have)
            return best
        def alloc(mode):
            """'group': per group, heaviest first, until it is good; 'abs' / 'norm': a global
            greedy, each step to the (group, colour) of the largest error drop (total, or per
            pixel of the group)."""
            slots = {z: [None] * DECO_SLOTS for z in screens}
            if mode == 'group':
                for g in groups:
                    while True:
                        b = best_colour(slots, g)
                        if b is None:
                            break
                        give(slots, g, b[1], b[2], b[3])
                return slots
            while True:
                best = None
                for g in groups:
                    b = best_colour(slots, g)
                    if b is None:
                        continue
                    gain = b[0] if mode == 'abs' else b[0] / sum(gpix[g].values())
                    if best is None or gain > best[0]:
                        best = (gain, g) + b[1:]
                if best is None:
                    return slots
                give(slots, best[1], best[2], best[3], best[4])
        # the allocation with the lowest worst group error (per group alone, the bridge took 7
        # slots for its last few pixels and the dugout's roof had none: a dark green roof)
        best = None
        for mode in ('group', 'abs', 'norm'):
            sl = alloc(mode)
            errs = [g_err(sl, g) for g in groups]
            key = (max(errs) if errs else 0, sum(e * sum(gpix[g].values()) for e, g in zip(errs, groups)))
            if best is None or key < best[0]:
                best = (key, sl, mode)
        slots = best[1]
        gslots = {g: g_use(slots, g)[0] for g in groups}   # group -> {slot: colour} usable by its LUT
        if os.environ.get('DECO_DEBUG'):
            for g in groups:
                print('set', s, 'group', g, best[2], 'err/px %.1f' % g_err(slots, g))
        # variants: one per distinct slot set (unused slots: black); zones from the positions
        variants, var_of = [], {}             # unused slots are wildcards: compatible zones merge
        for z in screens:
            for vi, v in enumerate(variants):
                if all(a is None or b is None or a == b for a, b in zip(v, slots[z])):
                    variants[vi] = [a if a is not None else b for a, b in zip(v, slots[z])]
                    var_of[z] = vi
                    break
            else:
                variants.append(list(slots[z]))
                var_of[z] = len(variants) - 1
        variants = [tuple(c if c is not None else (0, 0, 0) for c in v) for v in variants]
        if not variants:
            variants = [tuple([(0, 0, 0)] * DECO_SLOTS)]
        zones = []
        for P, z in seen:
            if z and (not zones or zones[-1][1] != var_of[z]):
                zones.append((P, var_of[z]))
        if not zones:
            zones = [(0, 0)]
        zones[0] = (0, zones[0][1])
        assert len(variants) <= MAX_VARIANTS and len(zones) <= MAX_ZONES, \
            'set %d: %d variants, %d zones' % (s, len(variants), len(zones))
        # LUT pages: page 0 = text colours only (decorations not in this set), then one per group
        pages = bytearray()
        def lut_page(p, cols):
            mp = [0 if pen == SPR_TRANSPARENT else min(cols, key=lambda ic: dist(pal[128 + 16 * p + pen], ic[1]))[0]
                  for pen in range(16)]
            return bytes(mp[b >> 4] << 4 | mp[b & 15] for b in range(256))
        txt_cols = [(i, txt_fixed[i]) for i in range(1, len(txt_fixed))]
        page_of = {}
        for k, (n, p) in enumerate(OVERLAY_SPRITES):
            g = next((g for g in present_g if (n, p) in DECO_GROUPS[g]), None)
            key = (g, p) if g is not None else None   # not in this set: any page
            if key is None and page_of:
                continue
            if key not in page_of:
                cols = txt_cols + ([(8 + i, c) for i, c in sorted(gslots[g].items())] if g is not None else [])
                if g in bg_match:       # the colours the background tiles show (block 0) only
                    cols = [ic for ic in cols if ic[1] in block0] or cols
                page_of[key] = len(pages) // 256
                pages += lut_page(p, cols)
        seg = bytearray(4 * deco_rows)
        for k, (n, p) in enumerate(OVERLAY_SPRITES):
            g = next((g for g in present_g if (n, p) in DECO_GROUPS[g]), None)
            seg[k] = page_of[(g, p)] if g is not None else 0
        ztab = bytearray()
        for P, v in zones:
            ztab += bytes([P & 255, P >> 8, v])
        ztab += b'\xFF\xFF\x00'
        assert len(pages) <= 8 * 256, 'set %d: %d LUT pages' % (s, len(pages) // 256)
        block1 = list(txt_fixed) + list(variants[zones[0][1]])
        vcols = bytearray()
        for v in variants:
            vcols += bytes(x for col in v for x in col)
        # set file: blocks 0 and 1 (96) at 0, the LUT page of each decoration at 96, zones
        # (position word, variant; $FFFF end) at 256, variant colours (block 1 entries 8-15,
        # 24 bytes each) at 448, LUT pages at 1024
        out = bytearray(3072)
        out[0:96] = bytes(x for col in block0 + block1 for x in col)
        out[96:96 + len(seg)] = seg
        out[192:240] = bytes(x for col in portrait_pal for x in col)
        out[256:256 + len(ztab)] = ztab
        out[448:448 + len(vcols)] = vcols
        out[1024:1024 + len(pages)] = pages
        open(os.path.join(OUT, 'set%d_pal.bin' % s), 'wb').write(out)
        info['zones%d' % s] = {'groups': {str(g): {str(8 + i): c for i, c in sorted(gslots[g].items())} for g in present_g},
                               'variants': len(variants), 'zones': ['%04X:%d' % z for z in zones]}
        if s == 0:
            set_pal0 = block0 + block1
        info['set%d' % s] = {'combos': nb, 'bytes': len(bg), 'strips': [lo, hi]}
        # preview: the strips of the set, quantised, bottom = lowest position
        prev = Image.new('RGB', (256, 64 * (hi - lo)))
        for k in range(lo, hi):
            for m in range(4):
                mt = rom[strips_addr + 4 * k + m]
                for r in range(4):
                    for t in range(4):
                        a = METATILES + 32 * mt + 2 * (4 * r + t)
                        code = rom[a] | ((rom[a + 1] & 0xC0) << 2); attr = rom[a + 1] & 0x3F
                        p = attr & 15
                        px = screen_pens(tile_pens[code], bool(attr & 0x10), bool(attr & 0x20))
                        im = Image.new('RGB', (16, 16))
                        im.putdata([tuple(v * 8 for v in block0[bg_lut[p][v]]) for row in px for v in row])
                        prev.paste(im, (64 * m + 16 * t, 64 * (hi - 1 - k) + 16 * r))
        prev.save(os.path.join(OUT, 'preview_set%d.png' % s))

    # ------------------------------------------------------------ global palette
    palette = set_pal0 + spr_block[2] + spr_block[3]
    open(os.path.join(OUT, 'palette.bin'), 'wb').write(bytes(v for c in palette for v in c))
    json.dump([list(k) for k in spr_combos], open(os.path.join(OUT, 'spr_combos.json'), 'w'))
    json.dump(info, open(os.path.join(OUT, 'assets.json'), 'w'), indent=1)
    print('font %d patterns, sprite atlas %d cells, sets: %s' % (
        nfont, natlas, ', '.join('%d' % info['set%d' % s]['combos'] for s in range(8))))

def index_table(items, nkeys, entry):
    """1024/768-word index by key[0] + lists of entries, $FF terminated.
    items: list of keys; entry(key, i) -> bytes for item i."""
    lists = collections.defaultdict(list)
    for i, key in enumerate(items):
        lists[key[0]].append(entry(key, i))
    out = bytearray(2 * nkeys)
    body = bytearray()
    for k in range(nkeys):
        if k in lists:
            off = 2 * nkeys + len(body)
            out[2 * k] = off & 255; out[2 * k + 1] = off >> 8
            for e in lists[k]:
                body += e
            body.append(0xFF)
    return bytes(out + body)

if __name__ == '__main__':
    main()
