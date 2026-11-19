#!/usr/bin/env python3
"""Model the arcade sound sequencer and log YM2203 writes per tick.

Usage: python3 tools/snd_model.py SOUND_ROM COMMAND [TICKS]
"""
import sys

class Driver:
    def __init__(self, rom, write):
        self.rom, self.write = rom, write
        self.tick_count = 0; self.last_cmd = 0
        self.groups = [[self.new_fm(i) for i in range(6)] for _ in range(4)]  # MUS_GRP1..4
        self.slots = [[self.new_ssg() for _ in range(4)] for _ in range(2)]   # SSG1/2 slot 0..3

    def new_fm(self, i):
        return dict(on=0, fhi=0, flo=0, len=0, keyon=0, gate=0, ch=i, gcnt=0, ptr=0,
                    lptr=0, lcnt=0, ins=0, tab=0, byte=0, tempo=0, tie=0, trip=0)

    def new_ssg(self):
        return dict(on=0, per=[0, 0, 0], noise=0, mix=0, vol=[0, 0, 0], tsl=[0, 0, 0],
                    vsl=[0, 0, 0], nsl=0, wait=0, ptr=0, lptr=0, lcnt=0, cur=0, nxt=0)

    def w16(self, a): return self.rom[a] | self.rom[a + 1] << 8

    def tick(self, latch):                      # one IRQ
        self.tick_count = (self.tick_count + 1) & 0xFF
        if latch != self.last_cmd:
            self.last_cmd = latch
            if latch != 0xFF: self.command(latch & 0x3F)
        self.fm_update(); self.ssg_update(); self.ssg_write()

    def command(self, c):                       # c = $00-$2E
        if c == 0 or 0x1C <= c <= 0x1F:         # stop all effects
            for chip in self.slots:
                for x in chip: x['on'] = 0
        elif c < 0x1C:                          # effect: ld ix,slot / ld hl,script
            h = self.w16(0x88 + 2 * c); slot = self.w16(h + 2); p = self.w16(h + 5)
            x = self.slots[(slot >> 8) - 0x45][(slot & 0xFF) >> 5]
            x.update(ptr=p, lptr=p, wait=0, lcnt=0, mix=0xFF, on=(x['on'] - 1) & 0xFF)
        elif c <= 0x2C:                         # music: call clear_grp / ld hl,header
            h = self.w16(0x88 + 2 * c)
            grp = {0x1F7: 0, 0x200: 1, 0x209: 2}[self.w16(h + 1)]
            self.mus_start(self.groups[grp], self.w16(h + 4))
        else:                                   # stop the music
            for g in self.groups: g[0]['on'] = 0
            for ch in range(3): self.write(1, 0x28, ch); self.write(2, 0x28, ch)

    # ---- music (FM)
    def mus_start(self, g, h):
        tempo = self.rom[h]
        for x in g: x['on'] = 0
        for i, x in enumerate(g):
            p = h + 1 + 4 * i
            x.update(on=0xFF, ch=i, ptr=self.w16(p), ins=self.rom[p + 2],
                     gate=self.rom[p + 3], tempo=tempo, len=0, tie=0, trip=0)
            self.load_patch(x)

    def chip_ch(self, x): return (1, x['ch']) if x['ch'] < 3 else (2, x['ch'] - 3)

    def load_patch(self, x):
        chip, ch = self.chip_ch(x); p = 0x0AA7 + 32 * x['ins']
        for i in range(24): self.write(chip, 0x30 + ch + 4 * i, self.rom[p + i])
        self.write(chip, 0xB0 + ch, self.rom[p + 24])
        x['keyon'] = (self.rom[p + 25] + ch) & 0xFF

    def fetch(self, x):
        x['byte'] = self.rom[x['ptr']]; x['ptr'] += 1; return x['byte']

    def key_on(self, x):
        t = x['tab'] + 2 * (x['byte'] & 0x1F)
        x['fhi'], x['flo'] = self.rom[t], self.rom[t + 1]
        chip, ch = self.chip_ch(x)
        self.write(chip, 0x28, x['keyon'])
        self.write(chip, 0xA4 + ch, x['fhi']); self.write(chip, 0xA0 + ch, x['flo'])

    def set_length(self, x, dotted):
        tab = (0, 0, 3, 6, 12, 24, 48, 96) if dotted else (0, 0, 2, 4, 8, 16, 32, 64)
        x['len'] = tab[x['byte'] >> 5] * x['tempo']
        g = (x['gate'] & 15) or 1
        x['gcnt'] = (x['len'] * (g + 1) >> 4) & 0xFFFF

    def fm_update(self):
        for g in reversed(self.groups):         # highest group whose channel 0 is on
            if g[0]['on']: break
        else: return
        for x in g:
            if x['on']:
                if x['trip'] and self.tick_count & 1: self.fm_step(x)
                self.fm_step(x)

    def fm_step(self, x):
        if x['len'] > 1:
            x['len'] -= 1
            if x['tie'] or x['gcnt'] == 0: return
            x['gcnt'] -= 1
            if x['gcnt'] == 0:
                chip, ch = self.chip_ch(x); self.write(chip, 0x28, ch)    # key off
            return
        x['trip'] = 0
        while True:
            b = self.fetch(x); lo = b & 0x1F
            if lo == 0:                         # rest
                x['fhi'] = x['flo'] = 0; self.set_length(x, False); return
            if lo == 0x1F:                      # control code
                op = b >> 5
                if op == 0: x['tab'] = 0x0135 + 2 * self.fetch(x)
                elif op == 1: x['tempo'] = self.fetch(x)
                elif op == 2: self.fetch(x)
                elif op == 3: lo_ = self.fetch(x); x['ptr'] = lo_ | self.fetch(x) << 8
                elif op == 4: x['lptr'] = x['ptr']; x['lcnt'] = 0
                elif op == 5:
                    n = self.fetch(x); x['lcnt'] = (x['lcnt'] + 1) & 0xFF
                    if n >= x['lcnt']: x['ptr'] = x['lptr']
                elif op == 6:                   # dotted note or rest
                    if self.fetch(x) & 0x1F: self.key_on(x)
                    else: x['fhi'] = x['flo'] = 0
                    self.set_length(x, True); return
                else:
                    x['on'] = 0; return         # end of channel
                continue
            if b < 0x20:                        # instrument change
                x['ins'] = b; x['gate'] = self.fetch(x); self.load_patch(x); continue
            if b < 0x40:                        # triplet / tie prefix
                if b == 0x30: x['trip'] = 1
                else: x['tie'] = (b + 1) & 0x1F
                continue
            if x['tie']: x['tie'] -= 1          # note
            self.key_on(x); self.set_length(x, False); return

    # ---- effects (SSG)
    def ssg_update(self):
        for chip in self.slots:
            for x in reversed(chip):            # highest active slot only
                if x['on']: self.ssg_run(x); break

    def sfetch(self, x):
        x['cur'] = self.rom[x['ptr']]; x['nxt'] = self.rom[x['ptr'] + 1]; x['ptr'] += 1
        return x['cur']

    def ssg_run(self, x):
        if x['wait']:
            x['wait'] -= 1; self.slides(x); return
        while True:                             # flow codes
            b = self.sfetch(x); op = (b >> 2) & 7
            if op == 0: x['wait'] = b << 8 | self.sfetch(x); break
            if op == 1: x['lptr'] = x['ptr']; x['lcnt'] = 0
            elif op == 2:
                n = self.sfetch(x); x['lcnt'] = (x['lcnt'] + 1) & 0xFF
                if n != x['lcnt']: x['ptr'] = x['lptr']
            elif op == 3: lo_ = self.sfetch(x); x['ptr'] = lo_ | self.sfetch(x) << 8
            else: x['on'] = 0; return
        s8 = lambda v: v - 256 if v & 0x80 else v
        while x['nxt'] & 0xE0:                  # register commands
            b = self.sfetch(x); op = b >> 5
            if op <= 3:
                n = op - 1; p = (b & 15) << 8 | self.sfetch(x)
                if p == 0: x['per'][n] = 0; x['mix'] |= 1 << n
                elif p != 0xFFF: x['per'][n] = p << 4; x['mix'] &= ~(1 << n) & 0xFF
                x['tsl'][n] = s8(self.sfetch(x))
            elif op <= 6:
                n = op - 4
                if b & 0x1F != 0x1F: x['vol'][n] = (b << 4) & 0xFF
                x['vsl'][n] = s8(self.sfetch(x))
            else:
                if b & 0x1F != 0x1F: x['noise'] = (b << 3) & 0xFF
                x['mix'] = (x['mix'] & 0xC7) | (self.sfetch(x) & 0x38)
                x['nsl'] = s8(self.sfetch(x))
        x['wait'] = (x['wait'] - 1) & 0xFFFF

    def slides(self, x):
        for n in range(3): x['per'][n] = (x['per'][n] + x['tsl'][n]) & 0xFFFF
        if self.tick_count & 3: return
        for n in range(3): x['vol'][n] = (x['vol'][n] + x['vsl'][n]) & 0xFF
        x['noise'] = (x['noise'] + x['nsl']) & 0xFF

    def ssg_write(self):
        for c, chip in enumerate(self.slots):
            regs = [0, 0, 0, 0, 0, 0, 0, 0xFF, 0, 0, 0]          # silence
            for x in reversed(chip):
                if x['on']:
                    regs = []
                    for n in range(3): regs += [x['per'][n] >> 4 & 0xFF, x['per'][n] >> 12]
                    regs += [x['noise'] >> 3, x['mix']] + [v >> 4 for v in x['vol']]
                    break
            for r in range(11): self.write(c + 1, r, regs[r])


def main():
    rom = open(sys.argv[1], 'rb').read()
    cmd = int(sys.argv[2], 16)
    ticks = int(sys.argv[3]) if len(sys.argv) > 3 else 2400
    log = []
    tick = [0]
    d = Driver(rom, lambda chip, reg, val: log.append((tick[0], chip, reg, val)))
    for t in range(1, ticks + 1):
        tick[0] = t
        d.tick(cmd if t == 1 else 0xFF)
    # key events: reg $28 (key on/off), $A4/$A0 pitch
    for t, chip, reg, val in log:
        if reg == 0x28:
            ch = (chip - 1) * 3 + (val & 3)
            print('%5d ch%d %s' % (t, ch, 'ON' if val & 0xF0 else 'off'))
        elif 0xA4 <= reg <= 0xA6:
            pass
        elif 0xA0 <= reg <= 0xA2:
            ch = (chip - 1) * 3 + (reg - 0xA0)
            print('%5d ch%d fnum_lo %02X' % (t, ch, val))
        elif reg < 0x10 and chip in (1, 2):
            pass

if __name__ == '__main__':
    main()
