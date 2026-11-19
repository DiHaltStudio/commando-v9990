"""Convert user-supplied Commando arcade dumps into local build inputs."""
from hashlib import sha256
from pathlib import Path
import sys

ASSETS = Path(__file__).resolve().parents[1] / 'assets'


def prepare(source, output):
    inputs = {}
    problems = []
    for line in (ASSETS / 'arcade-inputs.sha256').read_text().splitlines():
        checksum, name = line.split()
        try:
            data = (source / name).read_bytes()
        except OSError:
            problems.append(f'{name}: missing or unreadable')
            continue
        if sha256(data).hexdigest() != checksum:
            problems.append(f'{name}: does not match the Commando World set')
        inputs[name] = data
    if problems:
        raise ValueError(
            f'Arcade input directory: {source}\n' + '\n'.join(problems)
            + '\nExtract your Commando World set and set ARCADE_ROMS to its directory.'
        )

    raw = inputs['cm04.9m'] + inputs['cm03.8m']
    program = bytearray(raw)
    text = (ASSETS / 'arcade-opcode-addresses.txt').read_text()
    for line in text.splitlines():
        for offset in line.partition('#')[0].split():
            address = int(offset, 16)
            value = program[address]
            # The board exchanges bits 7–5 with 3–1 on Z80 M1 fetches.
            program[address] = (value & 0x11) | ((value & 0xe0) >> 4) | ((value & 0x0e) << 4)

    output.mkdir(parents=True, exist_ok=True)
    (output / 'main_src.bin').write_bytes(raw)
    (output / 'main_plain.bin').write_bytes(program)
    (output / 'sound.bin').write_bytes(inputs['cm02.9f'])


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('Usage: prepare_arcade.py ARCADE_ROMS OUTPUT_DIR')
    try:
        prepare(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
