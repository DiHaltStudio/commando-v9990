# Cartridge and engine design

## Startup and memory

The cartridge uses a 2 MiB ASCII16 mapper. Startup identifies the turbo R and V9990, displays credits on the MSX screen, and switches to R800 execution. It loads the DiHalt Studio logo and cartridge cover into V9990 VRAM. The logo fanfare uses the OPL4's sample memory. The transition to the cover uses graphics already loaded into VRAM. Starting the game switches to P1 tile mode.

The build places the arcade program into three 16 KiB banks. Hooks replace the board's I/O, scroll, graphics and sound paths. The resident runtime and frequent render tables use internal RAM to reduce cartridge accesses. The V9990 vertical retrace drives presentation and game timing.

## Graphics

P1 mode uses plane B for backgrounds, plane A for characters and foreground scenery, and hardware sprites for actors. The map converter prepares patterns and palettes for each area. The runtime builds new rows as the camera advances and updates palm trees, rocks and other foreground objects as their arcade state changes.

The sprite renderer constructs a V9990 attribute table in one of two VRAM staging buffers and transfers the completed frame during vertical retrace. Each HUD block has a dedicated sprite pattern. The renderer composes the two HUD bands from the score, life, grenade and medal text cells. During life entry and game over, central messages use priority sprites so that the letters remain visible through overlapping scenery and effects.

## Audio

The arcade sequencer's music plays through Yamaha OPL FM. The builder converts the local arcade sound data into frequency and instrument tables and samples the 240 Hz SSG effect sequences for OPL4 playback. With an OPL3-only setup, FM plays on the cartridge while PSG effects play through the MSX output. The logo fanfare uses separate DiHalt Studio instruments.

## Code and data

- [src/boot.asm](../src/boot.asm) handles startup and loading.
- [src/resident.asm](../src/resident.asm) implements bank switching, interrupt and arcade hooks.
- [src/overlay.asm](../src/overlay.asm) renders the map, text, HUD and sprites.
- [src/sound.asm](../src/sound.asm) implements the sound sequencer, FM and effect playback.
- [tools/build_port.py](../tools/build_port.py) defines the patches and packs code and assets into ASCII16 banks.
