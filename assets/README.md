# Build assets

- `dihalt_logo-b1.png`, `dihalt.mus` and `dihalt.pcm` are DiHalt Studio's startup logo, score and OPL4 samples.
- `arcade-inputs.sha256` identifies the user-supplied Commando World ROM files used by the build.
- `arcade-opcode-addresses.txt` lists hexadecimal offsets of Z80 opcode fetches. The importer applies the board's bit permutation only to those bytes of the supplied program.
- `vramstats.json` and `sprites_seen.json` contain tile and sprite usage frequencies. The graphics tools use them to allocate palettes and choose frequently accessed sprite patterns.

See [Building from source](../docs/BUILDING.md) for the local inputs and cover picture.
