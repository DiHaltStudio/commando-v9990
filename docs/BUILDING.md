# Building Commando V9990

| Requirement | Purpose |
| --- | --- |
| GNU Make | Build and packaging targets |
| Python 3.10 or later, NumPy and Pillow | Prepare inputs, build graphics and render sound effects |
| SJASM 0.42c on `PATH` | Assemble the Z80 code. The cartridge builder uses SJASM's listing and symbol output |
| `zip` | Package the ROM and PDFs |
| pdfLaTeX with `babel` for English and Spanish, DejaVu Sans and DejaVu Sans Bold | Rebuild the manuals |
| openMSX with the FS-A1ST or FS-A1GT system ROMs, GFX9000 and MoonSound | Play the cartridge or capture MSX gameplay |

## Local arcade inputs

Extract the **Commando (World)** arcade set into `local/arcade/commando/` or pass `ARCADE_ROMS=/path/to/directory`. The build reads the following files from the directory.

| Data | Files |
| --- | --- |
| Main Z80 program | `cm04.9m`, `cm03.8m` |
| Sound Z80 program and sequences | `cm02.9f` |
| Text patterns | `vt01.5d` |
| Sprite graphics | `vt05.7e`, `vt06.8e`, `vt07.9e`, `vt08.7h`, `vt09.8h`, `vt10.9h` |
| Background graphics | `vt11.5a`, `vt12.6a`, `vt13.7a`, `vt14.8a`, `vt15.9a`, `vt16.10a` |
| RGB palette PROMs | `vtb1.1d`, `vtb2.2d`, `vtb3.3d` |

The expected digests are in [arcade-inputs.sha256](../assets/arcade-inputs.sha256). Supply your own dumps. The original set, its disassembly and the decoded arcade data stay outside the source distribution.

## Cover picture

For the same cover as v1.0, download the [MSX cartridge](https://github.com/nwlg/commando-v9990/releases/tag/v1.0) and save it as `release/commando_v9990.rom`. Use `BASE_ROM=/path/to/commando_v9990.rom` to read it elsewhere. The builder takes only the 512×424 RGB332 picture from that file. It builds the program, sound and game graphics from the repository and the supplied arcade inputs.

To build with your own cover, pass `COVER_ART=/path/to/cover.png` or put it at `local/cover.png`. The builder scales it to 424 lines, centers it within 512 pixels and converts it to RGB332. For the full-size illustration and cartridge label in the PDFs, `make manual` reads the local cover image.

## Build and package

```sh
python3 -m venv build/venv
build/venv/bin/pip install -r requirements-build.txt
make PY=build/venv/bin/python
make release VERSION=1.0 PY=build/venv/bin/python
```

1. The import tool checks the local dumps against their SHA-256 digests, joins the two main program parts and decodes opcode bytes at the addresses listed in `assets/arcade-opcode-addresses.txt`. Operands and embedded data stay in their original format. Outputs go into `build/arcade/`.
2. The graphics tools convert the character, tile and sprite data to V9990 patterns and palettes. The audio tools create the OPL conversion tables and PCM effects.
3. SJASM assembles the port's startup, renderer, resident hooks and sound routines. The builder patches the imported program to use them and packs the cartridge into `build/port/commando_v9990.rom`.
4. `make release` writes the ROM, copies the two PDF manuals and packs all three into `release/Commando-V9990-v1.0.zip`.

| Target | Output |
| --- | --- |
| `make`, `make port` | Build the MSX cartridge |
| `make run`, `make run-st` | Play the release or local build on the FS-A1GT or FS-A1ST |
| `make shots`, `make shots-st` | Save timed screenshots from a local build to `build/shots/` |
| `make tmx` | Export Tiled views of maps and sprites to `build/tmx/` |
| `make manual` | Build both PDFs. Set `MANUAL_LANGS=en` or `MANUAL_LANGS=es` for one language |
| `make release VERSION=1.0` | Package the cartridge and the PDFs |
| `make clean` | Remove `build/`, including any virtual environment created inside it |
| `make help` | List the available targets |

Use `OPENMSX=/path/to/openmsx` for a different launcher. For screenshots, set `SH_TIMES` to a space-separated list of emulated seconds.
