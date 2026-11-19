#!/usr/bin/env python3
"""Build the DiHalt Studio logo and the cover for the V9990 start-up."""
from hashlib import sha256
import os
import sys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
LOGO = ROOT / 'assets/dihalt_logo-b1.png'
WIDTH, HEIGHT = 512, 424


def rgb332_palette():
    """The fixed BD8 palette: colour code GGGRRRBB, index == code."""
    palette = []
    for code in range(256):
        palette.extend((((code >> 2) & 7) * 255 // 7,
                        ((code >> 5) & 7) * 255 // 7,
                        (code & 3) * 255 // 3))
    return palette


def convert_cover(source):
    with Image.open(source) as art:
        image = art.convert('RGB')
    width = max(1, round(image.width * HEIGHT / image.height))
    if width > WIDTH:
        raise ValueError(f'{source}: scaled width {width} exceeds {WIDTH}')
    resized = image.resize((width, HEIGHT), Image.LANCZOS)
    reference = Image.new('P', (1, 1))
    reference.putpalette(rgb332_palette())
    dithered = resized.quantize(palette=reference, dither=Image.Dither.FLOYDSTEINBERG)
    output = Image.new('P', (WIDTH, HEIGHT), 0)
    output.paste(dithered, ((WIDTH - width) // 2, 0))
    return output.tobytes()


def opening_bytes():
    """Use a local cover image or the cover bank from the published MSX 1.0 ROM."""
    cover_art = Path(os.environ.get('COVER_ART') or ROOT / 'local/cover.png')
    if cover_art.is_file():
        return convert_cover(cover_art)
    if os.environ.get('COVER_ART'):
        raise ValueError(f'COVER_ART file is missing: {cover_art}')

    release_rom = Path(os.environ.get('BASE_ROM') or ROOT / 'release/commando_v9990.rom')
    if not release_rom.is_file():
        raise ValueError(
            'Place the v1.0 MSX ROM in release/commando_v9990.rom, '
            'set BASE_ROM to its path, or supply a local image with COVER_ART.'
        )
    with release_rom.open('rb') as rom:
        rom.seek(102 * 16384)
        data = rom.read(WIDTH * HEIGHT)
    if sha256(data).hexdigest() != '1a1195c6e34c5f31f8cd1d561c517863da36ebc1d61d80a763f2506ba4d92c0b':
        raise ValueError(f'{release_rom}: expected the cover bank from Commando V9990 v1.0')
    return data


def logo_bytes():
    """Two banks: 256x212 pixels at 4 bpp (left pixel in the high nibble, 27136 bytes), then the
    16-entry palette (R, G, B as 5-bit values) at offset 16384 + 16128. Entry 0 is the colour of
    the top-left pixel (also the border)."""
    image = Image.open(LOGO).convert('RGB')
    if image.size != (256, 212):
        raise ValueError(f'{LOGO}: expected 256x212, got {image.size}')
    corner = image.getpixel((0, 0))
    colours = [corner] + sorted(set(image.getdata()) - {corner})
    if len(colours) > 16:
        raise ValueError(f'{LOGO}: {len(colours)} colours, at most 16 fit a 4 bpp bitmap')
    index = {c: i for i, c in enumerate(colours)}
    pixels = [index[c] for c in image.getdata()]
    data = bytearray(b'\xff' * 32768)
    data[:27136] = bytes((pixels[i] << 4) | pixels[i + 1] for i in range(0, len(pixels), 2))
    for i, (r, g, b) in enumerate(colours):
        data[32512 + 3 * i:32515 + 3 * i] = bytes((r >> 3, g >> 3, b >> 3))
    return data


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] != 'build':
        sys.exit('Usage: build_opening.py build OUTPUT_DIR')
    try:
        artwork = opening_bytes()
        out = Path(sys.argv[2])
        out.mkdir(parents=True, exist_ok=True)
        (out / 'logo_b1.bin').write_bytes(logo_bytes())
        (out / 'opening_b3.bin').write_bytes(artwork)
    except (OSError, ValueError) as error:
        sys.exit(str(error))
