"""Build MoonSound one-shots and loops from the arcade's 240 Hz SSG scripts."""
import numpy as np

from snd_model import Driver


# First 128 KiB of OPL4 SRAM, wave numbers 384..411. The game replaces
# the temporary logo instruments once their notes have been damped.
RAM = 0x200000
COUNT = 28
SSG_CLOCK = 187500  # tone flips at SSG clock / period; noise shifts at / (2 * period)
AMPLITUDE = (0, 141, 222, 306, 441, 585, 836, 1112, 1595, 2146,
             3081, 4135, 6006, 8155, 11976, 16382)   # YM2149/YM2203 four-bit mode


def render(Driver, rom, cmd):
    driver = Driver(rom, lambda *args: None)
    driver.command(cmd)
    slot = next(s for group in driver.slots for s in group if s['on'])
    start = slot['ptr']
    seen = 0
    ticks = 0
    tone_count = [0] * 3
    tone_state = [0] * 3
    noise_count, noise_state = 0, 1
    audio = []
    while ticks < 8192:
        driver.tick_count += 1
        # These scripts loop by jumping to their first command. Take several
        # passes, so the free-running noise has some variation at the seam.
        if not slot['wait'] and rom[slot['ptr']] == 0x0c and driver.w16(slot['ptr'] + 1) == start:
            seen += 1
            if seen == 4:
                break
        driver.ssg_update()
        if not slot['on']:
            break
        clocks = (ticks + 1) * SSG_CLOCK // 240 - ticks * SSG_CLOCK // 240
        indices = np.arange(clocks)
        period = max(1, slot['noise'] >> 3) * 2
        edge = max(0, period - noise_count - 1)
        noise = np.full(clocks, noise_state & 1, dtype=np.int32)
        for pos in range(edge, clocks, period):
            noise_state = (noise_state >> 1) | (((noise_state ^ (noise_state >> 3)) & 1) << 16)
            noise[pos:pos + period] = noise_state & 1
        noise_count = clocks + noise_count if edge >= clocks else (clocks - 1 - edge) % period
        mix = np.zeros(clocks, dtype=np.int32)
        for ch in range(3):
            period = max(1, slot['per'][ch] >> 4)
            edge = max(0, period - tone_count[ch] - 1)
            flips = np.where(indices < edge, 0, 1 + (indices - edge) // period)
            state = (flips & 1) ^ tone_state[ch]
            tone_state[ch] = int(state[-1])
            tone_count[ch] = clocks + tone_count[ch] if edge >= clocks else (clocks - 1 - edge) % period
            gate = (state | ((slot['mix'] >> ch) & 1)) & (noise | ((slot['mix'] >> (ch + 3)) & 1))
            mix += gate * AMPLITUDE[slot['vol'][ch] >> 4]
        audio.append(mix)
        ticks += 1
    else:
        raise ValueError(f'unrecognised loop in effect {cmd:02x}')
    return (np.concatenate(audio) if audio else np.array([])), ticks, bool(seen)


def sample(signal, rate):
    # Band-limit before decimation. Subtract the low-frequency DC component
    # from the unipolar SSG DAC so loading/parking a wave does not send a click.
    ratio = rate / SSG_CLOCK
    radius = int(np.ceil(6 / ratio))
    pos = np.arange(-radius, radius + 1)
    kernel = np.sinc(pos * ratio * 0.92) * np.hamming(len(pos))
    filtered = np.convolve(signal, kernel / kernel.sum(), 'same')
    x = np.interp(np.arange(round(len(signal) * ratio)) / ratio, np.arange(len(signal)), filtered)
    dc = 0.0
    alpha = 1 - np.exp(-2 * np.pi * 15 / rate)
    for i, value in enumerate(x):
        dc += alpha * (value - dc)
        x[i] = value - dc
    return np.clip(np.rint(x * (127 / (3 * 16382 * 0.66))), -127, 127).astype('int8').tobytes()


def build(rom):
    effects = [render(Driver, rom, cmd) for cmd in range(1, COUNT)]
    banks = []
    # F-number 0 in octave -1 gives 11025 Hz. F-number 498 in octave -3
    # gives about 4097 Hz on the first-generation 128 KiB MoonSound.
    for rate in (11025, 44100 * (1024 + 498) / (1024 * 16)):
        data = bytearray(12 * COUNT)
        data[0] = 0x53  # upload readback marker in unused wave 384
        for cmd, (signal, ticks, loop) in enumerate(effects, 1):
            if not ticks:
                continue
            pcm = sample(signal, rate)
            loop_offset = 0 if loop else len(pcm)
            if not loop:
                pcm += bytes(2)  # park the one-shot at digital silence
            assert 0 < len(pcm) < 65536
            addr = RAM + len(data)
            header = (addr.to_bytes(3, 'big') + loop_offset.to_bytes(2, 'big') +
                      (-len(pcm) & 65535).to_bytes(2, 'big') + bytes([0, 0xf0, 0, 0x0f, 0]))
            data[cmd * 12:(cmd + 1) * 12] = header
            data.extend(pcm)
        banks.append(bytes(data))
    assert len(banks[1]) <= 128 * 1024
    durations = [0] + [65535 if loop else (ticks + 3) // 4 for _, ticks, loop in effects]
    return banks, durations
