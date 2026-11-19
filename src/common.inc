; =============================================================================
; Commando for MSX1 + V9990: definitions shared by boot, resident and overlay
; =============================================================================

; ---- V9990 ports
V9_VRAM         equ 060h        ; P#0 VRAM data (auto-increment)
V9_PAL          equ 061h        ; P#1 palette data
V9_CMD          equ 062h        ; P#2 command data
V9_REGD         equ 063h        ; P#3 register data
V9_REGS         equ 064h        ; P#4 register select
V9_STAT         equ 065h        ; P#5 status (b0 CE command executing, b6 VR vertical retrace)
V9_INT          equ 066h        ; P#6 interrupt flags (b0 VI)
V9_SYS          equ 067h        ; P#7 system control

; ---- VRAM map (P1)
VR_SGT          equ 000000h     ; sprite generator table: 256 slots of 16x16 (32 KB)
VR_PATA         equ 000000h     ; plane A pattern bitmap base (patterns from FONT_BASE are used)
VR_SPAT         equ 03FE00h     ; sprite attribute table (line 2044 of the 128-byte lines)
VR_STG_A        equ 03FA00h     ; staging SPAT images written by the build (line 2036 / 2040); the
VR_STG_B        equ 03FC00h     ; vertical interrupt copies the finished one to VR_SPAT with an LMMM
VR_PATB         equ 040000h     ; plane B pattern bitmap (64 KB at most)
VR_DECORAW      equ 060000h     ; raw pens of the plane A decorations (DECO_ROWS x 8 lines): load_set converts them
VR_DECOTMP      equ 066000h     ; the decorations converted for the next set during a load without blanking (copied to
                                ; OVL_BASE by an LMMM at the switch: converted in place they showed grey for 6 frames)
VR_TSMSIG       equ 07B000h     ; 28 x 8: the text cells (codes, attributes) each flight text slot was composed with
VR_SPRTMP       equ 06B000h     ; the next set's fixed sprite cells (SET_SPR_BYTES), staged during the flight and copied
                                ; to SGT slots 0..SPR_FIX-1 at the switch (VR_DECOTMP + the 19 rows ends at $6AC00)
VR_PNTA         equ 07C000h     ; plane A name table (64x64 words)
VR_PNTB         equ 07E000h     ; plane B name table
FONT_BASE       equ 1024        ; first plane A pattern of the font (below: the SGT)
FONT_Y          equ 256         ; bitmap line of FONT_BASE (= 8 * FONT_BASE / 32)

; ---- screen geometry
CROP_TOP        equ 24          ; first visible arcade screen line (of 256)

; ---- ASCII16 cartridge
BANK_P1         equ 06000h      ; bank register of page 1 ($4000-$7FFF)
BANK_P2         equ 07000h      ; bank register of page 2 ($8000-$BFFF)
BANK_BOOT       equ 0
BANK_ARC0       equ 1           ; arcade $0000-$3FFF (copied to RAM at boot)
BANK_ARC1       equ 2           ; arcade $4000-$7FFF
BANK_ARC2       equ 3           ; arcade $8000-$BFFF
BANK_OVL        equ 4           ; overlay: runtime code, org $8000
; BANK_FONTDIR, BANK_FONT, ... come from build/port/banks.inc (generated)

; ---- arcade symbols used by the runtime (from the disassembly)
ARC_RESET       equ 00000h
ARC_RST10       equ 00010h      ; VBLANK interrupt entry (di; jp vblank_irq)
ARC_BGOBJ_SLOTS equ 0E800h
ARC_BG_BUILD    equ 09F8Bh      ; bg_build_block: decode the next 64 px of the map, collision rows, tiles
ARC_LOAD_PARAMS equ 09FD7h      ; load_enemy_params (first part of bg_build_block)
ARC_DECODE_STRIP equ 0A6BDh     ; map_decode_strip: IX = scr block
ARC_TILE_PROPS  equ 06064h      ; tab_tile_props: collision shape per tile (code + 256 * attr b6-7)
ARC_STREAM_RESET equ 0A65Bh     ; map_stream_reset
ARC_MAP_RESTART equ 0A570h      ; map_restart
ARC_PLAYER_OBJ  equ 0E100h
ARC_HELI        equ 0E160h      ; heli +0: nonzero while the drop-off / pickup helicopter is active      ; player_obj +0: $FF alive, $3F kill request
ARC_CMD_HIT_SHOTS equ 0AF28h    ; cmd_hit_shots: the 6 player shots against the 8 soldiers (main-loop command $0C)
ARC_DSL_CONT    equ 02B8Eh      ; draw_sprite_list after its first 6 bytes (the hook runs them)
ARC_MAP_OBJS    equ 0E500h      ; 8 map objects x 32 bytes
ARC_CMD_RING_WR equ 0ED80h      ; cmd_ring_wr / cmd_ring_rd (low bytes): the main loop's command ring, 128 pairs at $E700 (patched)
ARC_CMD_RING_RD equ 0ED82h
ARC_CLEAR_PLAYFIELD_TEXT equ 00609h ; clear_playfield_text: rows 2-29, columns 0-29 := space
ARC_START_GAME  equ 005C9h      ; start_game: player 1 in turn, game_state 3 (game start), cmd 9 queued
ARC_IN_SYSTEM   equ 0E003h      ; in_system: IO_SYSTEM inverted (b0 START1, b1 START2)
ARC_TWO_PLAYERS equ 0E01Ah      ; two_player_game
ARC_SCR_BLOCK   equ 0EF00h      ; scr_pos_hi: the tile streamer block (IX); +5 scr_wrap_count, +$13 scr_resync_count
arc_game_state  equ 0E000h
arc_frame_count equ 0E002h
arc_credits     equ 0E030h
arc_scroll_hi   equ 0E05Bh      ; map position (16 bits)
arc_scroll_lo   equ 0E05Ch
arc_scroll_delta equ 0E062h     ; pixels the map moved this tick (0 or 1)
arc_pl_map_pos  equ 0EDA2h
arc_pl_area     equ 0EDA9h
arc_scr_block   equ 0EF00h      ; tile streamer block (IX)
TXT_CODE        equ 0D000h
TXT_ATTR        equ 0D400h
BG_CODE         equ 0D800h
BG_ATTR         equ 0DC00h
SPRITERAM       equ 0FE00h

; ---- arcade I/O shadows (page 3 RAM, read/written by the arcade code)
IO_SYSTEM       equ 0C000h      ; R: b0 START1, b1 START2, b6 COIN2, b7 COIN1 (active low)
IO_P1           equ 0C001h      ; R: b0 right, b1 left, b2 down, b3 up, b4 fire, b5 grenade (active low)
IO_P2           equ 0C002h
IO_DSW1         equ 0C003h
IO_DSW2         equ 0C004h
IO_SOUNDLATCH   equ 0C800h      ; W by the arcade
IO_CONTROL      equ 0C804h
IO_SPRITE_DMA   equ 0C806h
IO_SCROLLX_LO   equ 0C808h
IO_SCROLLX_HI   equ 0C809h
IO_SCROLLY_LO   equ 0C80Ah
IO_SCROLLY_HI   equ 0C80Bh      ; 1 while the area-clear picture is shown (plane X + 256)

; ---- runtime RAM (page 3, $C000-$CFFF; see resident.asm for the layout)
RT_VARS         equ 0C010h
code_in_ram     equ 0CFFCh      ; 1: page 2 executes from the internal turbo R mapper
CODE_SEG_OFS    equ 3           ; cartridge banks 3/4 are cached in RAM segments 6/7
p1_cur          equ RT_VARS+0   ; bank mapped on page 1 (shadow)
p2_cur          equ RT_VARS+1   ; bank mapped on page 2
in_tick         equ RT_VARS+2   ; 1 while the arcade tick runs (the interrupt then only presents)
frame_no        equ RT_VARS+3   ; frame counter (cache stamps)
cur_set         equ RT_VARS+4   ; asset set loaded ($FF none)
spr_hand        equ RT_VARS+5   ; sprite cache clock hand
start_bits      equ RT_VARS+6   ; IO_SYSTEM start bit (b0 START1, b1 START2) reported while start_hold
start_hold      equ RT_VARS+7   ; frames start is still reported
start_prev      equ RT_VARS+8   ; start buttons pressed on the previous frame
scby_cur        equ RT_VARS+9   ; 2: last SCBY written
hud_dirty       equ RT_VARS+11  ; HUD blocks need a rebuild
miss_count      equ RT_VARS+12  ; 2: cache misses (statistics)
fb_count        equ RT_VARS+14  ; 2: fallback uploads (statistics)
dbg_unknown     equ RT_VARS+16  ; 2: unknown combos (statistics)
v9_cmdbusy      equ RT_VARS+18  ; a cache copy command may still run
spat_n          equ RT_VARS+19  ; entries written in the last SPAT build
joy_h           equ RT_VARS+20  ; 3
joy_v           equ RT_VARS+23  ; 3
tick_debt       equ RT_VARS+26  ; frames whose tick was skipped (statistics)
in_hook         equ RT_VARS+27  ; 1 while a hook runs with the overlay mapped (no tick then)
in_build        equ RT_VARS+32  ; 1 while ovl_build runs (the interrupt keeps the previous SPAT)
ovl_refresh     equ RT_VARS+33  ; text erased on plane A: rewrite the decoration cells (next build)
bg_pending      equ RT_VARS+35  ; a 64-px strip of the map must be built (after the tick, not by the main loop)
bg_step         equ RT_VARS+36  ; strip build in progress: 1 decode, 2-5 collision rows (a quarter each), 6-13 tile columns (a half each), 14 tail
build_skips     equ RT_VARS+37  ; frames whose sprite build was skipped for the main loop (statistics)
bg_half         equ RT_VARS+38  ; column step: bits 1-2 column, bit 0 half (tiles 0-7 / 8-15)
disp_hold       equ RT_VARS+39  ; display off after a set load: 1 until the next build, 2 until a present in the retrace turns it on
pres_vr         equ RT_VARS+40  ; this present started in the vertical retrace (its scroll was written)
heli_on         equ RT_VARS+41  ; the helicopter (drop-off / pickup) is active in this build: its entries in front
ent_pr          equ RT_VARS+42  ; SPAT priority bit of the entry being built: $20 behind plane A, 0 in front
pal_hold        equ RT_VARS+43  ; set load without blanking (pickup flight -> next area): 1 the plane B writes wait (the
                                ; old cells and palette stay on screen); 2 the next map drawn in plane B's right half,
                                ; its present switches (palette, SCBX = 256); 3 the left half is drawn again at the next
                                ; build; 4 its present goes back to SCBX = 0
patb_hi         equ RT_VARS+44  ; plane B pattern numbers + 256 * this: 0 ($40000) or 8 ($50000), the half of the last load
keep_next       equ RT_VARS+45  ; spat_keep: next dynamic slot for a fixed slot on screen
bgx_or          equ RT_VARS+46  ; ovl_bg_cell: 16 = tiles 0-15 written to plane B's right half (columns 32-63)
bx_half         equ RT_VARS+47  ; 1: plane B's right half shown (SCBX = 256) during a switch without blanking
dbg_font_key    equ RT_VARS+28  ; 2: last unknown text combo (code, attribute)
dbg_bg_key      equ RT_VARS+30  ; 2: last unknown background combo (code, attribute)
hud_count       equ 0C040h      ; number of visible HUD entries preceding the actors
hud_presented   equ 0C041h      ; HUD entries in the live SPAT, retained by hide_sprites
dsl_calls       equ 0C080h      ; 8: draw_sprite_list calls of each map object slot this tick
dsl_any         equ 0C088h      ; static lists drawn since the last sweep
bgo_hits        equ 0C089h      ; active map structures (bgobj_slots) in bgo_hitlist, rebuilt by ovl_bgobj_all each tick
bgo_hitlist     equ 0C08Ah      ; 8 x 4: y, x, solid box offset and width of each (the hit tests walk this list)
hud_blk_dirty   equ 0C0B0h      ; 28: HUD block written since its last compose
hud_spat_dirty  equ 0C0CCh      ; a HUD block got or lost its sprite slot: the HUD SPAT entries are rebuilt
hud_state_last  equ 0C0CDh      ; in-game flag the HUD SPAT entries were built with
zone_lo         equ 0C0CEh      ; 2: plane A palette zone of the presented map position: first position
zone_hi         equ 0C0D0h      ; 2: end (next zone's first position)
zone_var        equ 0C0D2h      ; its variant (colours in block 1 entries 8-15; $FF = none written)
wipe_last       equ 0C0D3h      ; 2: map position / 8 of the last plane A bottom-row wipe
port_pal_on     equ 0C0D5h      ; block 0 holds the area-clear picture's palette
txt_shift       equ 0C0D6h      ; plane A text rows moved up by this many rows (3 while text sits at the bottom)
txt_shift_top   equ 0C0D7h      ; the highest text column moved (3: the bottom block only, 31: every row)
bgo_spr         equ 0C0D8h      ; 9: map structure slot drawn as sprites (it overlaps an earlier slot)
bs_deco         equ 0C0E1h      ; $80: the dynamic sprite being built is composed from the plane A decoration patterns
bs_deco_id      equ 0C0E2h      ; its decoration id (2k + flip Y)
bgo_e0          equ 0C0E3h      ; bgo_emit: the entry number of structure slot 0
bgo_en          equ 0C0E4h      ; bgo_emit: slot n
bgo_ec          equ 0C0E5h      ; bgo_emit: bottom-left code
bgo_exa         equ 0C0E6h      ; bgo_emit: x of the left column
bgo_exb         equ 0C0E7h      ; bgo_emit: x of the right column
spat_clear      equ 0C0E8h      ; the arcade hid all its sprites: the next present clears the V9990 SPAT too
fb_remap        equ 0C0EAh      ; CPU fallback upload of a palette 1 sprite: pen 3 (index 4) -> index 9
tsm_on          equ 0C0ECh      ; text drawn as sprites (the lap-end pickup flight: the map scrolls under it)
ov_umode        equ 0C0F2h      ; overlay_unput mode: 0 clear own cells, 1 write into blank cells (deco_under_id)
pcm_ready       equ 0CFF7h      ; preserved on boot: 1 full-rate/2 compact OPL4 effect bank, 0 use PSG
cheat_kill      equ 0CFFAh      ; boot (opening picture): $3F, or $FF with the hidden immunity trick (F1 + fire); kept by the resident copy
easy_adj        equ 0CFFBh      ; added to the enemy bullet speed class: 0 normal (START1), $FF easy (START2)
txt_down        equ 0C0F1h      ; rows the text columns 27-29 move down (under the top HUD band: name entry TIMER)
tsm_shift       equ 0C0EDh      ; its line offset (the text block moved down above the HUD band)
tsm_dirty       equ 0FDC8h      ; 25: text block b (196: 14 row pairs x 14 line pairs) to compose again
tsm_slot        equ 0FDE1h      ; 28: block of sprite slot 212 + i ($FF none)
tsm_last        equ 0CA00h      ; 28: block whose text sprite slot 212 + i holds, shown or not ($FF none); in
                                ; spr_blk_of's unused part (the cache reads it for slots SPR_FIX..239 only)
tsm_shown       equ 0CA20h      ; 25: text block b has a slot (bit b)
tsm_rp          equ 0CA40h      ; 28: row pair of the block shown in text slot 212 + i
tsm_lp          equ 0CA60h      ; 28: its line pair
tsm_cur         equ 0CA80h      ; 2: rp, lp of the block tsm_block works on
deco_tmp        equ 0CA82h      ; 1: decoration sprites composed from VR_DECOTMP (the build a switch presents)
lp_sxh          equ 0CA83h      ; lmmm_pat: source X bits 8-9 (2: the plane B half); 0 otherwise
pre_state       equ 0CA87h      ; flight preload of the next set: 0 idle, 1 patterns, 2 sprite cells, 3 decorations, 4 done
pre_set         equ 0CA88h      ; the set being preloaded
us_vram         equ 0CA89h      ; 3: VRAM write address of the upload slice job
us_bank         equ 0CA8Ch      ; its ROM bank (page 1)
us_hl           equ 0CA8Dh      ; 2: its address in the bank ($4000-$7FFF)
us_left         equ 0CA8Fh      ; 2: 256-byte blocks left
dc_line         equ 0CA91h      ; decoration conversion job: the next line (0-151)
brh_de          equ 0CA92h      ; 2: next cell of the sliced plane B redraw (0: not started)
brh_done        equ 0CA94h      ; the right half is drawn: the next build is the one whose present switches
brh_go          equ 0CA95h      ; the right half is being drawn (slices continue wherever the scroll is)
paused          equ 0CA84h      ; P pressed in a game: no arcade tick, the sound silenced
pause_prev      equ 0CA85h      ; key P last frame (b5 of row 4, 0 = pressed)
snd_paused      equ 0CA86h      ; the sound driver silenced the chips for the pause
set_pending     equ 0C0EBh      ; set + 1 to load once the area-clear picture is gone (0: none)
deco_block      equ 0C0E9h      ; bg_clear .. map_set_position: no decoration drawn (area clear, picture)
dsl_rec         equ 0C100h      ; 8 slots x 3 lists x 8: static structures drawn on plane A (x, M lo, M hi, list, seen, type); page-aligned
IM2_TABLE       equ 0C400h      ; 257 bytes of $C3 -> handler at $C3C3
ISR_ENTRY       equ 0C3C3h      ; jp isr
hud_cells       equ 0C510h      ; 28 blocks x 4: text cells last composed ($FF = none)
hud_slot        equ 0C580h      ; 28: SGT slot of each HUD block ($FF = not shown)
SPR_DYNAMIC     equ 176         ; 64 cached actor patterns, including the shared flight slots
SPAT_LIMIT      equ 125         ; the V9990 displays entries 0 through 124
spat_buf        equ 0C6F0h      ; 28 x 4 HUD attributes, between the RAM lookup code and dynamic owners
spr_owner       equ 0C600h      ; 256 x 2: key cached in each SGT slot ($FFFF free)
txt_blank_map   equ 0C810h      ; 128 bytes = 1024 bits: text cell is non-blank in VRAM
; ---- plane A decorations (arcade RAM gaps $F400-$F7FF and $FC00-$FDFF, cleared by the arcade reset;
; $F000-$F3FF is the arcade's tile buffer ring, $F800-$FBFF its collision map)
ovl_cache       equ 0FC00h      ; 96 x 4 = sprite entry - $200: (x, M lo, M hi | seen<<7, id); x = 0 none
ovl_list        equ 0C5A0h      ; 96: entry numbers of the records with cells on plane A (the sweep clears the stale ones)
ovl_count       equ 0C501h
txt_row_tab     equ 0F400h      ; 1024: plane A row + 1 where each text cell was placed (0 = none)
bgo_rec         equ 0FD80h      ; 9 x 8: map structure slots drawn on plane A (x, M lo, M hi, code, attr, seen, type); seen 2 = the slot was taken by a new structure
OVL_VARS        equ 0C890h      ; overlay variables (the overlay itself is ROM)
set_bank        equ OVL_VARS+0  ; first bank of the current asset set
sc_row          equ OVL_VARS+1
sc_cell         equ OVL_VARS+2  ; 2
hud_hl          equ OVL_VARS+4  ; 2
lookup_key      equ OVL_VARS+6  ; 2: (code, attribute) being looked up
spat_last       equ OVL_VARS+8  ; SPAT entries to upload this frame
spat_used       equ OVL_VARS+9  ; SPAT entries in use this frame
ov_rec          equ OVL_VARS+12 ; 2: decoration record being written
ov_id           equ OVL_VARS+14 ; decoration id = 2 * k + flip Y
ov_x            equ OVL_VARS+15
ovl_sweep_ctr   equ OVL_VARS+17 ; builds since the last sweep
txt_pos         equ OVL_VARS+24 ; 2: map position the text cells were placed with (a jump re-places them)
fb_flipx        equ OVL_VARS+18 ; CPU upload: mirror the rows (flip X)
fb_row          equ OVL_VARS+32 ; 8: a mirrored row
bgo_mode        equ OVL_VARS+40 ; map structure quads: 0 write, 1 clear
bgo_x           equ OVL_VARS+41
bgo_xa          equ OVL_VARS+42 ; x of the code-C column
bgo_xb          equ OVL_VARS+43 ; x of the code-C+1 column
bgo_flip        equ OVL_VARS+44
bgo_cur         equ OVL_VARS+45 ; 2: record being drawn
bgo_tmp         equ OVL_VARS+47 ; 3: (x, M lo, M hi) of the quad being written
bgo_calls       equ OVL_VARS+50 ; structure updates since the last sweep
bgo_dirty       equ OVL_VARS+58 ; the sway state changed: the next structure update checks every record
bgo_ebase       equ OVL_VARS+59 ; 2: sprite entry of structure slot 0 (debris sprites)
spat_cnt        equ OVL_VARS+61 ; SPAT entries written by the build so far
sc_colbase      equ OVL_VARS+62 ; 2: BG_CODE cell of tile 0 of the column being copied (its second half)
sc_first        equ OVL_VARS+10 ; first tile of the column half (0 or 8)
build_no        equ OVL_VARS+51 ; builds done (sprite cache stamps)
sway_code       equ OVL_VARS+52 ; heli_sway_trees: top-left code of the sway frame
sway_eff        equ OVL_VARS+53 ; its bottom-left code (the structure records' code while the helicopter hovers)
sway_hit        equ OVL_VARS+54 ; the sway ran since the last build
sway_on         equ OVL_VARS+55 ; the sway ran before the previous build: records follow sway_eff
build_pos       equ OVL_VARS+56 ; 2: map position of the last build (the scroll presented with its SPAT)
sc_bases        equ OVL_VARS+64 ; 32: plane B pattern bases of the 16 tiles of a strip column
lookup_last     equ OVL_VARS+96 ; 2: base of the last background combo looked up (lookup_key)
dsl_cur         equ OVL_VARS+98 ; 2: static structure record being drawn
dsl_attr        equ OVL_VARS+100 ; its list attribute
bs_front        equ OVL_VARS+16 ; direct table value of a dynamic sprite ($FE = in front of plane A)
bs_blk          equ OVL_VARS+19 ; its SPAT attribute byte
bs_slot         equ OVL_VARS+20 ; pattern slot of the sprite being built
spat_stg        equ OVL_VARS+21 ; staging buffer being built (0 = A, 1 = B)
spat_n_a        equ OVL_VARS+22 ; arcade entries used the last time in staging A
spat_n_b        equ OVL_VARS+23 ; ... in staging B
spat_ready      equ OVL_VARS+26 ; a finished staging image waits to be copied to the SPAT
spat_show       equ OVL_VARS+27 ; which one
vram_moved      equ OVL_VARS+28 ; the VRAM write address was changed during the build (resume the SPAT stream)
spr_stamp       equ 0C900h      ; 256: frame of last use of each slot
spr_blk_of      equ 0CA00h      ; 256: palette block << 6 of each cached slot
RES_CODE        equ 0CB00h      ; resident code part 2 ($CB00-$CFEF)
