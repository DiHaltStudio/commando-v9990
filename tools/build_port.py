#!/usr/bin/env python3
"""Build the MSX1 + V9990 ROM of the Commando port.

usage: make port        (prepare local arcade inputs and build the cartridge)

1. assets (tools/port_assets.py) -> build/port/assets/
2. bank layout -> build/port/banks.inc (bank numbers and sizes for the overlay)
3. assemble resident.asm ($C000 image), overlay.asm (bank 4), boot.asm (bank 0)
4. the arcade program (decoded locally from your arcade ROMs) with the
   patches of PATCHES (hooks into the resident runtime, see docs/DESIGN.md)
5. write build/port/commando_v9990.rom (ASCII16) and .sym
"""
import os, re, sys, subprocess, json
from pathlib import Path
from gen_pcm_sfx import build as build_pcm_sfx

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARC = os.path.join(ROOT, 'build', 'arcade')
B = os.path.join(ROOT, 'build', 'port')
A = os.path.join(B, 'assets')
SRC = os.path.join(ROOT, 'src')
BANK = 16384

def run(cmd, cwd=None):
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if r.returncode != 0 or 'rror' in r.stdout or 'rror' in r.stderr:
        print(r.stdout[-3000:], r.stderr[-2000:])
        sys.exit('command failed: %s' % ' '.join(cmd))
    return r

def read_sym(path):
    sy = {}
    for line in open(path):
        m = re.match(r'^(\S+): equ ([0-9A-F]+)h', line)
        if m:
            sy[m.group(1)] = int(m.group(2), 16) & 0xFFFF
    return sy

def sjasm(src, out, cwd):
    run(['sjasm', '-s', src, out], cwd=cwd)
    return read_sym(os.path.join(cwd, os.path.splitext(out)[0] + '.sym'))

# ---------------------------------------------------------------- patches
def text(t):
    return t.encode('latin-1').hex().upper()

# boot screen text (type_text): '#' + text layer address of the next line, '@' end; lines at
# columns 24, 22, ... from row 2 (28 cells)
TXT_WARNING = ('USE AND EXPORT OF THIS GAME#V\xD0WITH IN THE #T\xD0COUNTRY OF THE JAPAN#R\xD0'
               'IS IN VIOLATION OF #P\xD0COPYRIGHT LAW#N\xD0AND CONSTITUTES #L\xD0A CRIMINAL ACT@')
TXT_HOMAGE = ('THIS MSX V9990 TURBO R GAME#V\xD0IS JUST A HOMAGE TO THE#T\xD0'
              'ORIGINAL COMMANDO BY CAPCOM.#P\xD0PLEASE ENJOY IT.@')
# default ranking (rank_default): the 7 names, 10 characters each (the scores are kept)
RANK_NAMES = [(0x0192, 'VULGUS....', 'MSX.TURBOR'), (0x019F, 'SON.SON...', 'V9990.OPL4'),
              (0x01AC, 'HIGEMARU..', 'CAPCOM....'), (0x01B9, 'CAPCOM....', 'DIHALT2026'),
              (0x01C6, 'EXED.EXES.', 'F1.CHEAT..'), (0x01D3, 'COMANDO...', 'OPENING...'),
              (0x01E0, '..........', '..........')]
# tab_strings entry: text layer address, attribute, characters, '@'
STR_ONE_OR_TWO = '\xEA\xD0\x00ONE OR TWO PLAYERS@\xEA'
STR_PRESS_FIRE = '\xEF\xD0\x01PRESS FIRE TO START@'   # title row 7 col 15, palette 1

# (address, original bytes, replacement) ; replacement: list of ('call'|'jp', symbol) | ('db', bytes)
PATCHES = [
    # reset_init: clear $E000-$FFFE, not $FFFF (secondary slot register)
    (0x0068, '01FF1F', [('db', '01FE1F')], 'RAM clear length'),
    # text layer stores: set 2,h / ld (hl),X / res 2,h -> call txt_sync_X
    (0x0612, 'CBD43600CB94', [('call', 'txt_sync_00'), ('db', '000000')], 'clear_playfield_text'),
    (0x0B8F, 'CBD4360FCB94', [('call', 'txt_sync_0F'), ('db', '000000')], 'draw_smoke_cell'),
    (0x8101, '77CB94', [('call', 'txt_sync_a_set')], 'medal cells'),
    (0x8144, 'CBD471CB94', [('call', 'txt_sync_c'), ('db', '0000')], 'grenade =' ),
    (0x8179, 'CBD471CB94', [('call', 'txt_sync_c'), ('db', '0000')], 'put_char_right'),
    (0x81AB, 'CBD43600CB94', [('call', 'txt_sync_00'), ('db', '000000')], 'clear_text_cell'),
    (0x821A, 'CBD471CB94', [('call', 'txt_sync_c'), ('db', '0000')], 'ranking score 0'),
    (0x8231, 'CBD43600CB94', [('call', 'txt_sync_00'), ('db', '000000')], 'ranking name char'),
    (0x8249, 'CBD43601CB94', [('call', 'txt_sync_01'), ('db', '000000')], 'ranking name symbol'),
    (0x8626, 'CBD473CB94', [('call', 'txt_sync_e'), ('db', '0000')], 'draw_tile_block_cell'),
    (0x98F1, 'CBD43600CB941A77', [('db', '1A'), ('call', 'txt_put_a00'), ('db', '00000000')], 'entry_grid_char'),
    (0x9BBD, '77112000', [('call', 'txt_put_a_de20'), ('db', '00')], 'name field letter'),
    (0x9BEF, '362EC9', [('jp', 'txt_put_2E_ret')], 'name field RUB'),
    (0x9BF2, '362EC9', [('jp', 'txt_put_2E_ret')], 'name field RUB, first letter'),
    (0x9C3B, 'CBD472', [('call', 'txt_sync_d_ret')], 'name entry letter'),
    # Name entry: move the grid, name field and TIMER down two tile rows.
    # The old TIMER already got a two-row offset under the HUD (column 28).
    # Column 24 is below that special range and includes both offsets.
    (0x8482, '7CD0', [('db', '78D0')], 'name entry: TIMER label'),
    (0x99A1, '3CD1', [('db', '38D1')], 'name entry: TIMER seconds'),
    (0x848E, '79D1', [('db', '77D1')], 'name entry: dotted name field'),
    (0x9860, '79D1', [('db', '77D1')], 'name entry: first character'),
    (0x99B2, '79D1', [('db', '77D1')], 'name entry: copy the completed name'),
    (0x9BC6, 'B9D2', [('db', 'B7D2')], 'name entry: end of the ten characters'),
    (0x9BDB, '79D1', [('db', '77D1')], 'name entry: RUB lower bound'),
    (0x9866, 'D6D0', [('db', 'D4D0')], 'name entry: first selectable letter'),
    (0x98EA, 'D6D0', [('db', 'D4D0')], 'name entry: draw the letter grid'),
    (0x98BE, '40', [('db', '30')], 'name entry: soldier and shot origin'),
    (0x98DB, 'DD3605AC', [('call', 'entry_place_cursor'), ('db', '00')], 'name entry: align reticle'),
    # Stationary cursor rows have Y = $9C/$8C/$7C plus the same 0..7
    # fine-scroll offset. Block up on the first and down on the last row.
    (0x9AC0, 'FEACC8', [('db', 'FE9CD0')], 'name entry: top row bound'),
    (0x9ACF, 'FE8CC8', [('db', 'FE84D8')], 'name entry: bottom row bound'),
    (0x9C79, 'CBD471CB94', [('call', 'txt_sync_c'), ('db', '0000')], 'print_text_loop'),
    (0x9C91, 'CBD471CB94', [('call', 'txt_sync_c'), ('db', '0000')], 'erase_text'),
    (0x9CAA, 'CBD471CB94', [('call', 'txt_sync_c'), ('db', '0000')], 'print_char'),
    (0x9CBB, 'CBD471', [('call', 'txt_sync_c_keep')], 'print_score_p1 zero'),
    (0x9CD0, 'CBD471', [('call', 'txt_sync_c_keep')], 'print_score_p2 zero'),
    (0x9CE4, 'CBD471CB94', [('call', 'txt_sync_c'), ('db', '0000')], 'print_top_score zero'),
    (0x9D37, 'CBD471CB94', [('call', 'txt_sync_c'), ('db', '0000')], 'print_score_put'),
    (0x0E75, '122322B3E0', [('call', 'txt_typer_put'), ('db', '0000')], 'type_text'),
    (0x8163, '362019', [('call', 'txt_put20_add')], 'fill_spaces'),
    (0x0640, '362019', [('call', 'txt_put20_add')], 'clear_text_column7'),
    (0x8057, '322BD2', [('call', 'title_bonus_first')], 'first bonus digit at the raised position'),
    (0x806C, '3229D2', [('call', 'title_bonus_every')], 'recurring bonus digit at the raised position'),
    # background
    (0x09A4, 'CBD477CB94', [('call', 'bg_sync_a'), ('db', '0000')], 'draw_portrait_bg'),
    (0xA759, '0E04DD660C', [('jp', 'hook_copy_strip'), ('db', '0000')], 'map_copy_strip_bg'),
    (0xA792, '2100D8', [('jp', 'hook_bg_clear')], 'bg_clear'),
    (0x03B7, 'DD2104FE', [('jp', 'hook_hide'), ('db', '00')], 'hide_sprites'),
    (0xA58E, 'DD21AE71', [('call', 'hook_set_position'), ('db', '00')], 'map_set_position'),
    (0xA399, 'DD2100E8', [('jp', 'hook_bgobj_all'), ('db', '00')], 'bgobj_update_all'),
    (0xA362, 'DD3500', [('call', 'hook_spawn')], 'bgobj_find_slot'),
    (0xA2E8, '4EDD2100E8', [('call', 'hook_sway'), ('db', '0000')], 'heli_sway_trees'),
    (0x9F87, '1606FFC9', [('jp', 'hook_bg_build'), ('db', '00')], 'scroll_build_check'),
    (0xAF23, '160CC33800', [('jp', 'hook_hit_shots'), ('db', '0000')], 'queue_hit_shots'),
    (0x2B88, 'DD4604DD4E05', [('jp', 'hook_dsl'), ('db', '000000')], 'draw_sprite_list'),
    (0x8B93, 'DDE521CC8B', [('jp', 'hook_bgohit'), ('db', '0000')], 'bgobj_hit_test'),
    (0x903F, 'DDE5217890', [('jp', 'hook_projhit'), ('db', '0000')], 'proj_hit_bgobj'),
    (0x8F99, 'FD3600B5DD361401', [('jp', 'shot_start_flight'), ('db', '0000000000')],
     'clip an outward shot before its first flight step can wrap around the left edge'),
    # the main loop's command ring: 128 pairs at $E700 (unused by the arcade) instead of 32 at $ED00
    # (the port's main loop gets little CPU: a burst of commands at the game start overflowed it)
    (0x0040, 'FE40', [('db', 'FEFF')], 'queue_cmd: no wrap at $40 (the page wraps)'),
    (0x00B7, '2100ED', [('db', '2100E7')], 'reset_init: ring base'),
    (0x00C0, '1101ED', [('db', '1101E7')], 'reset_init: ring fill'),
    (0x00C5, '013F00', [('db', '01FF00')], 'reset_init: ring size'),
    (0x8017, 'FE40', [('db', 'FEFF')], 'run_command: no wrap at $40'),
    # crop: the player may not walk under the bottom of the visible area (y >= 8 + 20)
    (0x8C6F, 'FE08', [('db', 'FE1C')], 'player bottom limit'),
    # hidden immunity trick (F1 held while fire leaves the opening picture): the kill requests of
    # shots and contacts go through hook_kill ($3F, or $FF = still alive); explosions ($9259) and
    # deadly terrain ($8C89) still kill
    (0x18C5, '3E3F3200E1', [('call', 'hook_kill'), ('db', '0000')], 'crossing vehicle runs the player over'),
    (0x19C1, '3E3F3200E1', [('call', 'hook_kill'), ('db', '0000')], 'oncoming jeep/truck runs the player over'),
    (0x22D5, '3E3F3200E1', [('call', 'hook_kill'), ('db', '0000')], 'bunker shot in flight hits the player'),
    (0x34EF, '3E3F3200E1', [('call', 'hook_kill'), ('db', '0000')], 'jeep runs the player over'),
    (0xAED4, '3E3F3200E1', [('call', 'hook_kill'), ('db', '0000')], 'enemy projectile hits the player'),
    (0xAF16, '3E3F3200E1', [('call', 'hook_kill'), ('db', '0000')], 'soldier touches the player'),
    # one player, no coins, no DIP switches (user, 2026-10-13): fire / key 1 starts a normal game,
    # grenade / key 2 an easy one (enemy bullets one speed class slower); lives and bonus lives
    # keep the DIP constants of boot.asm
    (0x0414, '3A18E0A7C270053A30', [('db', '3A03E0E603C8'), ('jp', 'hook_start')],
     'attract_common: a start button starts the game (no credit screen)'),
    (0x03D1, '3A0CE0A7C2FC05', [('db', '00000000000000')], 'boot_text: no test mode (fire held)'),
    (0x8260, '3A18E0', [('db', 'C90000')], 'cmd_draw_credits: no CREDIT line'),
    (0x3142, 'C0', [('db', 'C9')], 'mobj_riverbank: the bank sprites never drawn (lighter copies of the '
     'gorge walls under them: the walls changed colour once no bunker was alive)'),
    (0x0B15, '21A9ED', [('db', 'CD4331')], 'area_clear_done: call joe_drop_stop (below)'),
    (0x3143, '114C31CD882BC3', [('db', 'AF3220E421A9ED')],
     'joe_drop_stop (in the dead rest of mobj_riverbank): joe_drop := 0, then ld hl,pl_area / ret. The '
     'drop-off helicopter of areas 1 and 5 leaves 7 frames before Super Joe\'s walk ends: joe_drop stayed '
     'active and finished at the next pickup (player_init: the player jumped to the start position)'),
    (0x314A, '88', [('db', 'C9')], 'joe_drop_stop: ret'),
    (0x9FF5, '0E003A2CE0A728020E01', [('db', '3AFBCF4F000000000000')],
     'load_params_index: C = easy_adj ($CFFB), not the Difficult DIP'),
    # The soldier title's command $0E prints its own raised copyright block.
    # The subsequent attract panels keep using the arcade print_copyright.
    (0x0437, 'CD3905', [('db', '000000')], 'soldier title: credits are printed with the bonus lines'),
    (0x049F, 'CDDC81', [('call', 'attract_draw_ranking')], 'select ranking layout before its first text write'),
    (0x04C0, 'CD0906', [('call', 'attract_clear_text')], 'clear ranking before returning to the soldier title'),
    (0x8047, '3A26E0', [('call', 'title_credits')], 'soldier title: print four credit lines'),
    (0x8351, text(STR_ONE_OR_TWO), [('db', text(STR_PRESS_FIRE))], 'title string: PRESS FIRE TO START'),
    (0x83AC, 'EBD0', [('db', 'EDD0')], 'raise first bonus two rows'),
    (0x83C3, 'E9D0', [('db', 'EBD0')], 'raise recurring bonus two rows'),
    (0x83DB, 'E9D0', [('db', 'EBD0')], 'raise alternate recurring bonus two rows'),
    (0x83C6, text('AND EVERY 100000 PTS@'), [('db', text('AND EVERY 10000 PTS @'))],
     'title: cmd_draw_bonus_info puts the interval digit over the 1: AND EVERY 50000 PTS (the arcade said 500000)'),
    (0x8282, '1F83', [('db', '5183')], 'string $06 (INSERT COIN) -> PRESS FIRE TO START'),
    (0x82A2, '3084', [('db', '5183')], 'string $16 (INSERT COIN) -> PRESS FIRE TO START'),
    (0x01EA, text(TXT_WARNING[:len(TXT_HOMAGE)]), [('db', text(TXT_HOMAGE))], 'boot screen text'),
] + [(addr, text(old), [('db', text(new))], 'default ranking name %d' % (i + 1))
     for i, (addr, old, new) in enumerate(RANK_NAMES)]

def apply_patches(img, sym):
    for addr, orig, repl, what in PATCHES:
        o = bytes.fromhex(orig)
        if img[addr:addr + len(o)] != o:
            sys.exit('patch %s at %04X: original bytes differ (%s)' % (what, addr, img[addr:addr + len(o)].hex().upper()))
        out = bytearray()
        for kind, arg in repl:
            if kind == 'db':
                out += bytes.fromhex(arg)
            else:
                if arg not in sym:
                    sys.exit('patch %s: unknown symbol %s' % (what, arg))
                v = sym[arg]
                out += bytes([0xCD if kind == 'call' else 0xC3, v & 255, v >> 8])
        if len(out) != len(o):
            sys.exit('patch %s: length %d != %d' % (what, len(out), len(o)))
        img[addr:addr + len(o)] = out

def main():
    os.makedirs(B, exist_ok=True)
    run([sys.executable, os.path.join(ROOT, 'tools', 'port_assets.py'), ARC, A])
    info = json.load(open(os.path.join(A, 'assets.json')))
    # ---- bank layout
    def nbanks(n):
        return (n + BANK - 1) // BANK
    sizes = {k: os.path.getsize(os.path.join(A, k)) for k in os.listdir(A) if k.endswith('.bin')}
    banks = {}
    rom = []            # list of (bank index, bytes)
    nxt = 5
    pcm_space = []  # unused tails of packed graphics / audio assets (ROM offsets)
    def place(name, data):
        nonlocal nxt
        banks[name] = nxt
        nxt += nbanks(len(data))
        rom.append((banks[name], data))
        if len(data) % BANK:
            pcm_space.append((banks[name] * BANK + len(data), nxt * BANK))
    place('FONT', open(os.path.join(A, 'font.bin'), 'rb').read())
    place('ATLAS', open(os.path.join(A, 'spr_atlas.bin'), 'rb').read())
    place('FONTDIR', open(os.path.join(A, 'font_direct.bin'), 'rb').read())
    place('RAW', open(os.path.join(A, 'spr_raw.bin'), 'rb').read())
    place('PAL', open(os.path.join(A, 'palette.bin'), 'rb').read())   # the boot palette (64 entries)
    # ---- sound: the driver (src/sound.asm, assembled below) followed by the arcade sound ROM's data
    snd_rom = open(os.path.join(ARC, 'sound.bin'), 'rb').read()
    assert len(snd_rom) == BANK, 'sound ROM size %d' % len(snd_rom)
    run([sys.executable, os.path.join(ROOT, 'tools', 'gen_sound.py'), os.path.join(ARC, 'sound.bin'), os.path.join(B, 'sound_tabs.inc')])
    banks['SOUND'] = nxt
    snd_bank = nxt
    nxt += 1
    set_bytes = []
    banks['SET0'] = nxt
    SET_BANKS = 8
    for s in range(8):
        bg = open(os.path.join(A, 'set%d_bg.bin' % s), 'rb').read()
        idx = open(os.path.join(A, 'set%d_bgidx.bin' % s), 'rb').read()
        pal = open(os.path.join(A, 'set%d_pal.bin' % s), 'rb').read()
        spr = open(os.path.join(A, 'set%d_spr.bin' % s), 'rb').read()
        smap = open(os.path.join(A, 'set%d_sprmap.bin' % s), 'rb').read()
        assert len(bg) <= 4 * BANK, 'set %d patterns too big' % s
        assert len(idx) <= 8192 - 3072 and len(smap) <= 8192 and len(pal) == 3072
        data = bytearray(bg) + bytearray(4 * BANK - len(bg))
        # bank 4: palettes, decoration pages, zones, variants, LUT pages (setN_pal.bin) at 0,
        # background index at 3072, sprite map at 8192
        last = bytearray(BANK)
        last[0:3072] = pal
        last[3072:3072 + len(idx)] = idx
        last[8192:8192 + len(smap)] = smap
        sidx = open(os.path.join(A, 'spr_idx.bin'), 'rb').read()      # the same in every set (the overlay is full)
        assert len(smap) <= 3072 and len(sidx) <= BANK - 11264
        last[11264:11264 + len(sidx)] = sidx
        pcm_space.append((nxt * BANK + len(bg), (nxt + 4) * BANK))
        pcm_space.append(((nxt + 5) * BANK + len(spr), (nxt + 7) * BANK))
        data += last
        # banks 5-6: the fixed sprite cells (SGT layout, slots 0-207); bank 7: the direct table
        data += bytearray(spr) + bytearray(2 * BANK - len(spr))
        data += open(os.path.join(A, 'set%d_sprdirect.bin' % s), 'rb').read()
        rom.append((nxt, bytes(data)))
        set_bytes.append(len(bg))
        nxt += SET_BANKS
    # ---- start-up pictures (tools/build_opening.py): the DiHalt logo (B1) and the cover (B3)
    run([sys.executable, os.path.join(ROOT, 'tools', 'build_opening.py'), 'build', B])
    place('LOGO', open(os.path.join(B, 'logo_b1.bin'), 'rb').read())
    place('OPENING', open(os.path.join(B, 'opening_b3.bin'), 'rb').read())
    fanfare_pcm = open(os.path.join(ROOT, 'assets', 'dihalt.pcm'), 'rb').read()
    fanfare_music = open(os.path.join(ROOT, 'assets', 'dihalt.mus'), 'rb').read()
    assert 0 < len(fanfare_pcm) < 65536 and len(fanfare_music) <= BANK
    place('FANFARE_PCM', fanfare_pcm)
    place('FANFARE_MUSIC', fanfare_music)
    # The OPL4 samples fit in the unreferenced padding of the fixed-bank
    # graphics sets plus the final ROM banks. Keep all existing bank numbers.
    images, durations = build_pcm_sfx(snd_rom)
    pcm_space.append((nxt * BANK, 128 * BANK))
    def bank_ranges():
        for start, stop in pcm_space:
            while start < stop:
                end = min(stop, (start // BANK + 1) * BANK)
                yield start, end
                start = end
    ranges = bank_ranges()
    start, end = next(ranges)
    pcm_writes = []
    with open(os.path.join(B, 'pcm_chunks.inc'), 'w') as f:
        for label, data in zip(('pcm_large', 'pcm_small'), images):
            f.write(label + ':\n')
            pos = 0
            while pos < len(data):
                if start == end:
                    gap = next(ranges, None)
                    if gap is None:
                        raise ValueError('OPL4 samples exceed free space in the 2 MiB cartridge')
                    start, end = gap
                n = min(end - start, len(data) - pos)
                f.write('        db %d\n        dw %d,%d\n' %
                        (start // BANK, 0x8000 + start % BANK, n))
                pcm_writes.append((start, data[pos:pos + n]))
                nxt = max(nxt, (start + n + BANK - 1) // BANK)
                start += n
                pos += n
            f.write('        db 255\n')
    with open(os.path.join(B, 'pcm_durations.inc'), 'w') as f:
        f.write('        dw ' + ','.join(map(str, durations)) + '\n')
    total_banks = nxt
    rom_banks = 1
    while rom_banks < total_banks:
        rom_banks *= 2
    font_lines = len(open(os.path.join(A, 'font.bin'), 'rb').read()) // 128
    atlas_y = ((256 + font_lines + 15) // 16) * 16
    with open(os.path.join(B, 'banks.inc'), 'w') as f:
        f.write('; generated by tools/build_port.py\n')
        for k in ('FONT', 'ATLAS', 'FONTDIR', 'RAW', 'PAL', 'SOUND', 'SET0', 'LOGO', 'OPENING', 'FANFARE_PCM', 'FANFARE_MUSIC'):
            f.write('BANK_%s\tequ %d\n' % (k, banks[k]))
        f.write('FANFARE_BYTES\tequ %d\n' % len(fanfare_pcm))
        f.write('FONT_BYTES\tequ %d\n' % sizes['font.bin'])
        f.write('PATA_BLANK\tequ %d\nPATA_BLACK\tequ %d\n' % (info['font']['blank'], info['font']['black']))
        f.write('OVL_BASE\tequ %d\n' % info['font']['ovl_base'])
        f.write('OVL_END\tequ %d\n' % (info['font']['ovl_base'] + 8 * info['font']['overlays']))
        f.write('DECO_ROWS\tequ %d\nDECO_FONT_OFF\tequ %d\n' % (info['font']['deco_rows'], 32 * (info['font']['ovl_base'] - 1024)))
        f.write('ATLAS_BYTES\tequ %d\n' % sizes['spr_atlas.bin'])
        f.write('ATLAS_Y\tequ %d\n' % atlas_y)
        f.write('SET_BANKS\tequ 8\nSET_DIRECT_BANKOFF\tequ 7\nSET_PAL_BANKOFF\tequ 4\nSET_PAL_OFF\tequ 0\nSET_SEG_OFF\tequ 96\nSET_PORT_OFF\tequ 192\nSET_ZONE_OFF\tequ 256\nSET_VAR_OFF\tequ 448\nSET_LUT_OFF\tequ 1024\nSET_IDX_OFF\tequ 3072\nSET_SMAP_OFF\tequ 8192\nSET_SIDX_OFF\tequ 11264\nSET_SPR_BANKOFF\tequ 5\nSET_SPR_BYTES\tequ %d\nSPR_FIX\tequ %d\nSPR_GUN0\tequ %d\nGUN_DOWN\tequ %d\nHELI_SLOTS\tequ %d\n' % (len(open(os.path.join(A, 'set0_spr.bin'), 'rb').read()), info['sprites']['fixed'], info['sprites']['gun0'], info['sprites']['gun_down'], info['sprites']['heli']))
        for s in range(8):
            f.write('SET%d_BYTES\tequ %d\n' % (s, set_bytes[s]))
    # the asset tool must agree on ATLAS_Y: it only writes cells from 0; the overlay adds ATLAS_Y
    # ---- assemble
    sym_res = sjasm('resident.asm', '../build/port/resident.bin', SRC)
    with open(os.path.join(B, 'resident.inc'), 'w') as f:
        f.write('; generated: resident symbols used by boot.asm\n')
        for k in ('boot_go', 'isr', 'txt_write', 'set_p2'):
            f.write('%s\tequ 0%04Xh\n' % (k, sym_res[k]))
    res = open(os.path.join(B, 'resident.bin'), 'rb').read()
    assert len(res) == 0x1000, 'resident image size %d' % len(res)
    run([sys.executable, os.path.join(ROOT, 'tools', 'gen_bgobj.py'), os.path.join(B, 'bgobj_slots.inc')])
    run([sys.executable, os.path.join(ROOT, 'tools', 'gen_spat.py'), os.path.join(B, 'spat_chain.inc')])
    sym_ovl = sjasm('overlay.asm', '../build/port/overlay.bin', SRC)
    ovl = open(os.path.join(B, 'overlay.bin'), 'rb').read()
    assert len(ovl) == BANK, 'overlay size %d' % len(ovl)
    with open(os.path.join(B, 'sound_syms.inc'), 'w') as f:
        f.write('; generated: overlay symbols used by sound.asm\n')
        for k in ('snd_cmd_tab', 'opl_note_tab', 'opl4_note_tab', 'opl_patch_tab'):
            f.write('%s\tequ 0%04Xh\n' % (k, sym_ovl[k]))
    sjasm('sound.asm', '../build/port/sound.bin', SRC)
    snd = open(os.path.join(B, 'sound.bin'), 'rb').read()
    SND_DATA = 0x0AA7           # tab_fm_patch: the first data the driver needs (the code before it is replaced)
    assert len(snd) <= SND_DATA, 'sound driver too big: %d bytes (%d free)' % (len(snd), SND_DATA)
    rom.append((snd_bank, bytes(snd) + bytes(SND_DATA - len(snd)) + snd_rom[SND_DATA:]))
    sym_boot = sjasm('boot.asm', '../build/port/boot.bin', SRC)
    boot = open(os.path.join(B, 'boot.bin'), 'rb').read()
    assert len(boot) <= BANK, 'boot bank too big (%d)' % len(boot)
    boot += bytes(BANK - len(boot))
    # ---- arcade program
    arc = bytearray(open(os.path.join(ARC, 'main_plain.bin'), 'rb').read())
    assert len(arc) == 0xC000
    apply_patches(arc, sym_res)
    # ---- ROM
    image = bytearray(b'\xFF' * (rom_banks * BANK))
    image[0:BANK] = boot
    image[BANK:2 * BANK] = arc[0x0000:0x4000]
    image[2 * BANK:3 * BANK] = arc[0x4000:0x8000]
    image[3 * BANK:4 * BANK] = arc[0x8000:0xC000]
    image[4 * BANK:5 * BANK] = ovl
    for bank, data in rom:
        image[bank * BANK:bank * BANK + len(data)] = data
    for start, data in pcm_writes:
        assert all(v in (0, 255) for v in image[start:start + len(data)]), 'PCM would overwrite live asset data'
        image[start:start + len(data)] = data
    with open(os.path.join(B, 'commando_v9990.sym'), 'w') as f:
        for name, sy in (('res', sym_res), ('ovl', sym_ovl), ('boot', sym_boot)):
            for k, v in sorted(sy.items(), key=lambda kv: kv[1]):
                f.write('%s: equ %04Xh\n' % (k, v))
    out = Path(B) / 'commando_v9990.rom'
    pending = out.with_suffix(f'.rom.{os.getpid()}.tmp')
    try:
        pending.write_bytes(image)
        pending.replace(out)
    finally:
        pending.unlink(missing_ok=True)
    # Keep a single flashable image in the cartridge output directory.
    for other in out.parent.iterdir():
        if other != out and other.suffix.lower() == '.rom' and other.is_file():
            other.unlink(missing_ok=True)
    print('ROM: %s (%d KiB, %d banks used of %d)' % (out, len(image) // 1024, total_banks, rom_banks))
    print('font %d patterns, atlas %d cells at y %d, sets %s' % (
        info['font']['patterns'], info['sprites']['cells'], atlas_y, set_bytes))

if __name__ == '__main__':
    main()
