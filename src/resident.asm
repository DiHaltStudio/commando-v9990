; =============================================================================
; Commando for MSX1 + V9990: resident runtime, page 3 RAM image $C000-$CFFF
; (copied from the boot bank). It is always mapped, so it holds everything
; that runs while the overlay bank is not on page 2: the interrupt handler,
; the bank switching, and the hook stubs called from the arcade code.
;
;   $C000-$C00F  arcade input shadows (IO_SYSTEM.. IO_DSW2)
;   $C010-$C03F  variables (RT_VARS)
;   $C040-$C1FF  HUD counts, map structures and static sprite records
;   $C200-$C3C2  resident code part 1 (bank switching, the interrupt handler)
;   $C3C3        jp isr (IM2 vector $C3C3)
;   $C400-$C500  IM2 vector table ($C3 x 257)
;   $C510-$C5FF  HUD tables
;   $C600-$C7FF  sprite cache owners, fixed-slot scratch, lookup code and HUD attributes
;   $C800-$C80F  arcade output shadows
;   $C810-$C88F  text blank map; $C890-$C8FF overlay variables
;   $C900-$C9FF  sprite cache stamps; $CA00-$CAFF sprite palette blocks
;   $CB00-$CFEF  resident code part 2 (RES_CODE: hook stubs)
;   $CFF0-$CFFF  boot stack and variables (not copied by the boot: cheat_kill)
; =============================================================================
        include "common.inc"
        include "../build/port/banks.inc"

        org 0C000h
        ds 0C200h-$,0

; ---------------------------------------------------------------- part 1
        org 0C200h
; Map bank A on page 2 (shadow first). Keeps all registers.
set_p2:
        ld (p2_cur),a
        push af
        ld a,(code_in_ram)
        or a
        jr z,.cart
        ld a,(p2_cur)
        add a,CODE_SEG_OFS
        out (0FEh),a
        pop af
        ret
.cart:  pop af
        ld (BANK_P2),a
        ret
; Map bank A on page 1. Keeps all registers.
set_p1:
        push af
        ld (p1_cur),a
        ld (BANK_P1),a
        pop af
        ret

; end of the boot: page 1 := arcade bank, start the arcade program
boot_go:
        ld a,BANK_ARC1
        ld (p1_cur),a
        ld (BANK_P1),a
        jp ARC_RESET

; =============================================================================
; IM 2 handler (vector $C3C3 -> isr): V9990 vertical interrupt.
; Presents the frame (overlay), reads the inputs, then runs the arcade's own
; VBLANK handler (RST $10 entry), which ends with EI and RET.
; =============================================================================
isr:
        push af
        push bc
        push de
        push hl
        push ix
        push iy
        in a,(V9_INT)
        and 1
        jp z,.other
        ld a,1
        out (V9_INT),a          ; acknowledge VI
        ld a,(p1_cur)
        ld b,a
        ld a,(p2_cur)
        ld c,a
        push bc                 ; banks of the interrupted code
        ld a,BANK_OVL
        call set_p2
        call 08003h             ; ovl_present (page 1 is set by it as needed)
        ld a,BANK_SOUND
        ld (p1_cur),a
        ld (BANK_P1),a
        call 04000h             ; the sound driver: 4 ticks (240 Hz) and the PSG registers
        pop bc
        ld a,b
        ld (p1_cur),a
        ld (BANK_P1),a
        ld a,c
        call set_p2
        ; the arcade tick, unless the previous one is still running or the
        ; interrupted code is a hook (overlay mapped, overlay variables in
        ; use): then this frame has no tick (tick_debt counts them).
        ; The tick and the sprite build run with interrupts ENABLED, so the
        ; next vertical interrupt always presents inside the blanking; this
        ; handler then only presents (in_tick set).
        ld a,(paused)           ; the pause: only the present (and the inputs)
        or a
        jp nz,.done
        ld a,(in_tick)
        ld hl,in_hook
        or (hl)
        jp nz,.late
        inc a
        ld (in_tick),a
        ld a,(p1_cur)
        ld b,a
        ld a,(p2_cur)
        ld c,a
        push bc                 ; banks of the interrupted code
        ld a,BANK_ARC1
        ld (p1_cur),a
        ld (BANK_P1),a
        ld a,BANK_ARC2
        call set_p2
        ld hl,0
        ld (dsl_calls),hl       ; the static structure lists drawn this tick, per map object slot
        ld (dsl_calls+2),hl
        ld (dsl_calls+4),hl
        ld (dsl_calls+6),hl
.tick:  ei
        call ARC_RST10+1        ; the arcade tick body (skipping its DI): ends with EI, RET
        ; the next 64-px strip of the map, if the tick asked for it (bg_build_block runs
        ; in the arcade's main loop; here it would come too late: unpainted top rows and
        ; a stale collision map). One step per frame: the strip decode, the collision
        ; rows, the 4 tile columns, the streamer tail. The arcade routines use the
        ; alternate registers of the interrupted code: saved around the step.
        ld a,(bg_step)
        or a
        jr nz,.bgstep
        ld a,(bg_pending)
        or a
        jr z,.nobg
        xor a
        ld (bg_pending),a
        inc a
        ld (bg_step),a
.bgstep:
        exx
        push bc
        push de
        push hl
        exx
        ex af,af'
        push af
        ex af,af'
        call bg_build_step
        ex af,af'
        pop af
        ex af,af'
        exx
        pop hl
        pop de
        pop bc
        exx
.nobg:
        ; the arcade's main loop (text, score commands) gets ~2-8 ms per frame here
        ; against ~10 in the arcade; a burst of commands (game start) overflowed its
        ; ring (now 128 pairs at $E700, patched), and once the writer laps the reader
        ; the commands are lost or come a lap late. With 32 or more pending, this
        ; frame skips the sprite build (the previous frame stays) so the main loop
        ; gets the time.
        ld a,(ARC_CMD_RING_WR)
        ld hl,ARC_CMD_RING_RD
        sub (hl)
        cp 64
        jr c,.build
        ld hl,build_skips
        inc (hl)
        jr .tick_banks
.build: ; sprites and HUD of the next frame (overlay), interrupts enabled
        di
        ld a,BANK_OVL
        call set_p2
        ei
        call 08015h             ; ovl_build
        di
        ld a,BANK_ARC2
        call set_p2
        ld a,BANK_ARC1
        ld (p1_cur),a
        ld (BANK_P1),a
.tick_banks:
        pop bc
        ld a,b
        ld (p1_cur),a
        ld (BANK_P1),a
        ld a,c
        call set_p2
        xor a
        ld (in_tick),a
.done:  pop iy
        pop ix
        pop hl
        pop de
        pop bc
        pop af
        ei
        ret
.late:  ld hl,tick_debt         ; a tick that overran its frame is not caught up: the game slows
        inc (hl)                ; down evenly, as the arcade would (the counter is statistics only)
        jr .done
.other: in a,(099h)             ; a TMS9918 interrupt (should not happen: disabled)
        jr .done

; The name-entry grid is on plane A. Text placement rounds its scroll down
; to the previous tile boundary, so it appears 0..7 lines above the nominal
; row. Match that offset in the cursor's world Y (positive upwards). The
; arcade also uses this coordinate as the endpoint for each shot.
entry_place_cursor:
        ld a,(arc_scroll_lo)
        neg
        add a,CROP_TOP
        and 7
        add a,09Ch              ; first grid row after moving it down 16 px
        ld (ix+5),a
        ret

; The soldier title is the only attract panel with room for a fourth credit.
; Command $0E is executed by the arcade main loop with both arcade banks mapped.
; Use the original strings and its text writer (DE = chars, HL = cell, C = palette).
title_credits:
        ld c,5
        ld de,083F5h            ; CAPCOM
        ld hl,TXT_CODE+13*32+7
        call 09C74h
        ld de,083FFh            ; COPYRIGHT 1985
        ld hl,TXT_CODE+9*32+6
        call 09C74h
        ld de,08411h            ; ALL RIGHTS RESERVED
        ld hl,TXT_CODE+6*32+5
        call 09C74h
        ld de,.studio
        ld hl,TXT_CODE+10*32+3  ; twelve cells centred in the 28-cell playfield
        call 09C74h
        ld a,(0E026h)           ; resume cmd_draw_bonus_info with bonus_first
        ret
.studio: db "DIHALT  2026@"

; The attract ranking shares the previous logo panel's footer. Its seventh
; score also needs that space, so raise the whole table before drawing it.
attract_draw_ranking:
        ld hl,31*256+2          ; txt_shift = 2 rows, txt_shift_top = all columns
        ld (txt_shift),hl
        jp 081DCh               ; arcade cmd_draw_ranking

attract_clear_text:
        call ARC_CLEAR_PLAYFIELD_TEXT   ; erase using the panel's current layout
        ld hl,0
        ld (txt_shift),hl       ; initial layout for the next title or game
        ret

; At the left limit Joe is at x=16 and his left-facing muzzle is at x=1.
; A first step to the left can wrap directly to 255, past the arcade's
; post-move x<16 check. Keep the muzzle flash for its full duration, then
; free the bullet only if its signed 8.8 step would cross x=0.
shot_start_flight:
        bit 7,(ix+0Bh)          ; high byte of signed horizontal velocity
        jr z,.fly
        ld a,(ix+4)
        add a,(ix+0Ch)          ; fractional x + fractional velocity
        ld a,(ix+3)
        adc a,(ix+0Bh)          ; adding a negative velocity: no carry = left underflow
        jp nc,0901Dh            ; proj_free: clear the slot and hide its sprite
.fly:   ld (iy+0),0B5h          ; arcade flying bullet
        ld (ix+014h),1
        jp 08FA1h               ; shot_flight

        ds ISR_ENTRY-$,0
        org ISR_ENTRY
        jp isr
        ds IM2_TABLE-$,0
        org IM2_TABLE
        ds 257,ISR_ENTRY>>8     ; any bus byte -> $C3C3

; ---------------------------------------------------------------- part 2
        ds RES_CODE-$,0
        org RES_CODE
; Hook stubs: called from the arcade code with the arcade banks mapped. They
; map the overlay on page 2 (and the asset bank on page 1 as needed), call
; the implementation and restore the arcade banks. The interrupt may fire
; inside: it saves and restores the shadows, so the banks come back right.
; Registers: the implementation gets the caller's registers; AF is kept
; around the bank switching with the stack.

; generic: jump here with the overlay entry in IY? No: one stub per hook,
; each a 'call' into the overlay through hook_call with the entry in HL.
; HL = overlay entry (the caller's HL is passed on the stack where needed).
; Called from arcade code (main loop or tick). Interrupts stay enabled; the
; interrupt handler does not run a tick while in_hook is set.
hook_call:
        ld a,i                  ; P/V = IFF2: were interrupts enabled?
        push af
        di
        ld a,(in_hook)
        push af                 ; nested hook: keep the flag
        ld a,1
        ld (in_hook),a
        ld a,BANK_OVL
        call set_p2
        pop af
        pop bc                  ; C = flags with P/V
        push bc
        push af
        bit 2,c
        jr z,.noei1
        ei
.noei1: call .go
        di
        ld a,BANK_ARC2
        call set_p2
        ld a,BANK_ARC1
        ld (p1_cur),a
        ld (BANK_P1),a
        pop af
        ld (in_hook),a
        pop af
        ret po                  ; interrupts were off: leave them off
        ei
        ret
.go:    jp (hl)

; arcade kill sites of shots and contacts (PATCHES): the kill request, or $FF (alive) with the immunity trick
hook_kill:
        ld a,(cheat_kill)
        ld (ARC_PLAYER_OBJ),a
        ret

; ---- text layer stores: the arcade idiom "set 2,h / ld (hl),X / res 2,h"
; patched to "call txt_sync_X / nop / nop". The code byte is already in the
; shadow at HL; the attribute X goes to HL+$400, then the cell is sent to
; plane A. Keeps all registers (the arcade code relies on it).
txt_sync_c:
        set 2,h
        ld (hl),c
        res 2,h
        jr txt_sync
txt_sync_a:
        set 2,h
        ld (hl),a
        res 2,h
        jr txt_sync
txt_sync_e:
        set 2,h
        ld (hl),e
        res 2,h
        jr txt_sync
; name entry field: "ld (hl),a / ld de,$0020" (a letter) and "ld (hl),$2E / ret" (RUB)
txt_put_a_de20:
        ld (hl),a
        ld de,020h
        jp txt_sync
txt_put_2E_ret:
        ld (hl),02Eh
        jp txt_sync
; "ld (hl),a" then the attribute 0 (entry grid: the code is written first)
txt_put_a00:
        ld (hl),a
txt_sync_00:
        set 2,h
        ld (hl),000h
        res 2,h
        jr txt_sync
txt_sync_01:
        set 2,h
        ld (hl),001h
        res 2,h
        jr txt_sync
txt_sync_0F:
        set 2,h
        ld (hl),00Fh
        res 2,h
        jr txt_sync
; "ld (hl),a / res 2,h" after a "set 2,h" already executed (H points at the attribute)
txt_sync_a_set:
        ld (hl),a
        res 2,h
        jr txt_sync
; "set 2,h / ld (hl),c" with H left pointing at the attribute (the caller reloads HL)
txt_sync_c_keep:
        set 2,h
        ld (hl),c
        push hl
        res 2,h
        call txt_sync
        pop hl
        ret
; "set 2,h / ld (hl),d / ret": H stays pointing at the attribute
txt_sync_d_ret:
        set 2,h
        ld (hl),d
        push hl
        res 2,h
        call txt_sync
        pop hl
        ret
; the typer: "ld (de),a / inc hl / ld (typer_src),hl", cell at DE, code A, attribute unchanged
txt_typer_put:
        ld (de),a
        inc hl
        ld (0E0B3h),hl          ; typer_src
        push hl
        ex de,hl
        call txt_sync
        ex de,hl
        pop hl
        ret
; fills: "ld (hl),$20 / add hl,de" (fill_spaces, clear_text_column7): code only
txt_put20_add:
        ld (hl),020h
        call txt_sync
        add hl,de
        ret
; The two bonus digits follow their title records two text rows upwards.
title_bonus_first:
        push hl
        ld hl,TXT_CODE+022Dh
        jr title_bonus_put
title_bonus_every:
        push hl
        ld hl,TXT_CODE+022Bh
title_bonus_put:
        ld (hl),a
        call txt_sync
        pop hl
        ret

; Send the text cell at HL (code in the shadow, attribute at HL+$400) to the
; plane A name table. A space written over a cell that is already blank in
; VRAM is skipped (txt_blank_map: one bit per cell, 1 = non-blank in VRAM),
; which makes the screen clears cheap. Keeps all registers.
txt_sync:
        push af
        push bc
        push de
        push hl
        ld a,h
        cp 0D4h
        jp nc,.skip             ; not a code cell (defensive)
        cp 0D0h
        jp c,.skip
        ; a HUD column (0, 1, 30, 31): the HUD sprites are recomposed
        ld a,l
        and 31
        cp 2
        jr c,.hud
        cp 30
        jr c,.nohud
.hud:   push hl                 ; its block (rows 2-29: 14 blocks of 2 rows per band) is marked
        ld a,l
        rrca
        rrca
        rrca
        rrca
        rrca
        and 7
        ld b,a
        ld a,h
        and 3
        rlca
        rlca
        rlca
        or b                    ; row
        sub 2
        jr c,.noblk
        cp 28
        jr nc,.noblk
        srl a
        ld b,a
        ld a,l
        and 31
        cp 2
        jr nc,.topb
        ld a,b
        add a,14                ; bottom band
        ld b,a
.topb:  ld hl,hud_blk_dirty
        ld a,b
        add a,l
        ld l,a
        ld (hl),1
        ld a,1                  ; publish after the block flag: VBlank can preempt this writer
        ld (hud_dirty),a
.noblk: pop hl
.nohud:
        ; bit of the cell in txt_blank_map: byte (index >> 3), bit (index & 7)
        ld a,l
        and 7
        ld b,a
        ld a,(hl)
        ld c,a                  ; code
        ld a,l
        rrca
        rrca
        rrca
        and 01Fh
        ld e,a
        ld a,h
        and 3
        rlca
        rlca
        rlca
        rlca
        rlca
        or e
        ld e,a
        ld d,0
        push hl
        ld hl,txt_blank_map
        add hl,de               ; HL = map byte
        ld a,1
        inc b
.sh:    dec b
        jr z,.bit
        rlca
        jr .sh
.bit:   ld d,a                  ; D = bit mask
        call txt_is_space       ; (a code $20 of tiles $120-$3FF is graphics: the logo)
        jr nz,.nonblank
        ld a,(hl)
        and d
        jr z,.skip2             ; blank over blank: nothing to send
        ld a,(hl)
        xor d
        ld (hl),a               ; now blank in VRAM
        ld a,1
        ld (ovl_refresh),a      ; a decoration under the text gets its cell back
        jr .send
.nonblank:
        ld a,(hl)
        or d
        ld (hl),a
.send:  pop hl
        push hl
        call txt_write          ; the cell at HL -> plane A (resident, no overlay)
.skip2: pop hl
.skip:  pop hl
        pop de
        pop bc
        pop af
        ret

; Text cell at HL -> plane A name table. Plane A scrolls with the map, so
; the row depends on the map position P at the time of the write:
; row = (28 - col + floor((CROP_TOP - P) / 8)) & 63, X = row r. The row used
; is kept in txt_row_tab (+1, 0 = none): a later write of the same cell with
; another P clears the old place first. Rows 0-1 and 30-31 (margins) and the
; HUD columns 0, 1, 30, 31 (sprites) are not written. Pattern = font direct
; table (ROM, page 1 switched here and restored). Interrupts off around the
; port sequences. Uses AF, BC, DE, HL.
; (txt_write) a column 0-1 cell while the text is not moved up: its plane A
; place, if any, cleared. HL = cell, D = row r.
txt_hudcol:
        push de
        ld a,h
        and 3
        add a,txt_row_tab>>8
        ld h,a
        ld a,(hl)
        or a
        jr z,.done
        ld (hl),0
        pop de
        dec a
        ld e,d                  ; X = r
        ld d,a                  ; the old row
        ld hl,PATA_BLANK
        jp txt_cell_out
.done:  pop de
        ret
txt_write:
        ld a,h
        and 3
        rlca
        rlca
        rlca
        ld d,a
        ld a,l
        rlca
        rlca
        rlca
        and 7
        or d
        ld d,a                  ; D = row r
        cp 2
        ret c
        cp 30
        ret nc
        ld a,l
        and 31
        ld e,a                  ; E = col c
        cp 30
        ret nc
        cp 2
        jr nc,.col
        ld a,(txt_shift)        ; columns 0-1: the bottom HUD band (sprites); on plane A only
        or a                    ; while the text is moved up (txt_follow), else an old place
        jp z,txt_hudcol         ; there is cleared
.col:   ld a,(tsm_on)           ; text as sprites (pickup flight): its block composed again
        or a
        jp nz,txt_tsm_mark
        ld c,(hl)               ; code
        set 2,h
        ld b,(hl)               ; attribute
        res 2,h
        push hl                 ; the cell
        push de
        ; pattern from the direct table: bank BANK_FONTDIR + (pal >> 3), word (pal & 7) * 1024 + char
        ld a,(p1_cur)
        push af
        ld a,b
        and 008h
        rrca
        rrca
        rrca
        add a,BANK_FONTDIR
        ld (p1_cur),a
        ld (BANK_P1),a
        ld a,b
        and 0C0h
        rlca
        rlca
        ld h,a
        ld a,b
        and 7
        rlca
        rlca
        or h                    ; (pal & 7) << 2 | char bits 8-9: word index bits 15-8 before the doubling
        ld h,a
        ld l,c
        add hl,hl               ; byte address of the word (char low << 1, carry into H)
        set 6,h
        ld e,(hl)
        inc hl
        ld d,(hl)               ; DE = pattern
        pop af
        ld (p1_cur),a
        ld (BANK_P1),a
        pop bc                  ; B = row r, C = col c
        ; plane row of the cell now
        push de
        ld a,(arc_scroll_hi)
        ld h,a
        ld a,(arc_scroll_lo)
        ld l,a
        ld a,CROP_TOP
        sub l
        ld l,a
        ld a,0
        sbc a,h
        ld h,a                  ; HL = CROP_TOP - P (signed)
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,h
        and 63                  ; floor((CROP_TOP - P) / 8) mod 64
        add a,28                ; row 28 - c when SCAY = 0 (cell c at line 224 - 8c)
        sub c
        ld l,a
        ld a,(txt_shift_top)    ; text at the bottom: the rows up to txt_shift_top moved up
        cp c                    ; (txt_follow)
        ld a,l
        jr c,.nosh
        ld hl,txt_shift
        sub (hl)
.nosh:  ld l,a
        ld a,c                  ; columns 27-29 (under the top HUD band) moved down
        cp 27                   ; (txt_follow)
        ld a,l
        jr c,.nod
        ld hl,txt_down
        add a,(hl)
.nod:   and 63
        ld c,a                  ; C = plane row
        pop de
        pop hl                  ; the cell
        ; txt_row_tab[cell]: clear the old place if it was elsewhere
        push de
        ld a,h
        and 3
        add a,txt_row_tab>>8
        ld h,a                  ; HL = row table entry (same low 10 bits)
        ld a,(hl)
        or a
        jr z,.place
        dec a
        cp c
        jr z,.place             ; same row: overwritten below
        push bc
        push hl
        ld d,a                  ; old row
        ld e,b                  ; X = r
        ld hl,PATA_BLANK
        call txt_cell_out
        ld a,1
        ld (ovl_refresh),a      ; a decoration cell may have been under the old place
        pop hl
        pop bc
.place: ld a,c
        inc a
        ld (hl),a
        pop hl                  ; HL = pattern
        ld d,c                  ; row
        ld e,b                  ; X
        ; fall through
; write the word HL at plane A cell (X = E, row = D); interrupts off around the ports
txt_cell_out:
        push hl
        ld a,d
        and 63
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,e
        or l
        ld l,a
        add hl,hl               ; (row * 64 + X) * 2
        ld a,i
        push af
        di
        xor a
        out (V9_REGS),a
        ld a,l
        out (V9_REGD),a
        ld a,h
        add a,0C0h              ; + $C000 (VR_PNTA low 16 bits)
        out (V9_REGD),a
        ld a,VR_PNTA>>16
        out (V9_REGD),a
        pop af
        pop hl
        push af
        ld a,l
        out (V9_VRAM),a
        ld a,h
        out (V9_VRAM),a
        pop af
        ret po
        ei
        ret

; ---- background: draw_portrait_bg inner store "set 2,h / ld (hl),a / res 2,h"
bg_sync_a:
        set 2,h
        ld (hl),a
        res 2,h
        push af
        push bc
        push de
        push hl
        ex de,hl                ; DE = the cell
        ld hl,ovl_bg_cell
        call hook_call
        pop hl
        pop de
        pop bc
        pop af
        ret

; ---- whole-routine replacements (the arcade routine is patched with "jp hook_x")
hook_copy_strip:                ; map_copy_strip_bg: IX = streamer block
        ld hl,ovl_copy_strip
        jp hook_call
hook_bg_clear:                  ; bg_clear
        ld hl,ovl_bg_clear
        jp hook_call
hook_hide:                      ; hide_sprites (replaces `ld ix,SPRITERAM+4`): the V9990 SPAT is
        ld ix,SPRITERAM+4       ; cleared at the next present as well (the build may be skipped
        ld a,1                  ; for a while then, and the last SPAT stayed: the player over the
        ld (spat_clear),a       ; black screen of the area clear)
        jp 003BBh
hook_spawn:                     ; bgobj_find_slot: a structure takes the slot IX; its plane A record
        dec (ix+0)              ; (the instruction replaced by the call) is marked stale (seen = 2)
        push af
        push hl
        push ix
        pop hl
        ld a,l
        and 0F0h
        rrca
        add a,(bgo_rec&255)+5
        ld l,a
        ld h,bgo_rec>>8
        ld (hl),2
        pop hl
        pop af
        ret
hook_bgobj_all:                 ; bgobj_update_all: the whole update of the map structures (palm
        ld hl,ovl_bgobj_all     ; trees, rocks) runs in the overlay, one hook call per tick
        jp hook_call
hook_sway:                      ; heli_sway_trees: HL -> the sway frame's top-left code; replaces
        ld c,(hl)               ; `ld c,(hl) / ld ix,bgobj_slots` (the arcade then writes the hidden entries)
        ld a,c
        ld (sway_code),a
        push bc
        ld hl,ovl_sway
        call hook_call
        pop bc
        ld ix,ARC_BGOBJ_SLOTS
        ret
; one step of the strip build (bg_step 1-14), arcade banks mapped, interrupts enabled:
; 1 strip decode, 2-5 a quarter of the collision rows each, 6-13 half a tile
; column each, 14 the streamer tail (the arcade's bg_build_block does it all in
; one go: ~20 ms; a step here is at most ~2 ms)
bg_build_step:
        ld a,(bg_step)
        ld ix,ARC_SCR_BLOCK
        dec a
        jr nz,.s2
        call ARC_LOAD_PARAMS
        ld ix,ARC_SCR_BLOCK
        call ARC_DECODE_STRIP
        jr .next
.s2:    cp 5
        jr nc,.s6
        call props_step
        jr .next
.s6:    sub 5
        cp 8
        jr nc,.tail
        ld (bg_half),a
        ld hl,ovl_copy_column
        call hook_call
        jr .next
.tail:  dec (ix+013h)           ; scr_resync_count (the tail of bg_build_block)
        jr nz,.done
        call ARC_STREAM_RESET
        ld ix,ARC_SCR_BLOCK
        dec (ix+5)
        jr nz,.done
        call ARC_MAP_RESTART
.done:  xor a
        ld (bg_step),a
        ret
.next:  ld hl,bg_step
        inc (hl)
        ret
; map_build_props, 16 tiles per call (the arcade does the 64 of the strip at
; once): tile buffer ring (ix+8/9) -> collision map ring (ix+$A/B), 2 bytes
; per tile (shape from tab_tile_props, mirrored flag); the ring pointers
; carry on between the calls. Uses the alternate registers like the arcade.
props_step:
        ld d,(ix+8)
        ld e,(ix+9)
        exx
        ld d,(ix+0Ah)
        ld e,(ix+0Bh)
        ld b,16
.l:     exx
        ld a,(de)
        inc de
        ld hl,ARC_TILE_PROPS
        add a,l
        ld l,a
        jr nc,.nc
        inc h
.nc:    ld a,(de)
        ld c,a
        inc de
        rlca
        rlca
        and 3
        add a,h
        ld h,a
        ld a,(hl)
        exx
        ld (de),a
        inc de
        exx
        ld a,c
        rlca
        rlca
        rlca
        and 1
        exx
        ld (de),a
        inc de
        djnz .l
        ld a,d
        and 0FBh                ; ring $F800-$FBFF
        ld (ix+0Ah),a
        ld (ix+0Bh),e
        exx
        ld a,d
        and 0F3h                ; ring $F000-$F3FF
        ld (ix+8),a
        ld (ix+9),e
        ret
hook_dsl:                       ; draw_sprite_list: IX = object, IY = first sprite entry, DE = list.
        ld a,(ix+013h)          ; a static map structure (bunker, bridge, gorge, river bank, dugout)
        and 03Fh                ; goes to plane A instead (ovl_dsl); anything else: the arcade routine
        ld l,a
        ld h,dsl_static>>8
        ld a,(hl)
        or a
        jr z,.arcade
        cp 2
        jr c,.static            ; 1: every list of the object
        ld b,a                  ; 2 (dugout), 3 (fortress gate): the first value - 1 lists always
        cp 3                    ; (lintel, pillars); the dugout's door also while closed (+14 = 0:
        jr z,.cnt               ; the opening animation slides the door by the pixel: sprites); the
        ld a,(ix+014h)          ; fortress door never (its cells and the pillars' share cells: closed,
        or a                    ; its sides were lost; as sprites the pillars' cells mask them)
        jr z,.static
.cnt:   push ix
        pop hl
        ld a,l
        rrca
        rrca
        rrca
        rrca
        rrca
        and 7                   ; object slot
        ld hl,dsl_calls
        add a,l
        ld l,a
        ld a,(hl)
        inc a
        cp b
        jr c,.static            ; one of the always-static lists of the tick
.arcade:
        ld b,(ix+4)             ; (the 6 bytes replaced by the jump)
        ld c,(ix+5)
        jp ARC_DSL_CONT
.static:                        ; the record of (slot, n-th list of the tick): when it matches the
        push ix                 ; object (x, M = y + P, list) the cells are in place: seen, and IY
        pop hl                  ; and DE advance as the arcade would; else the overlay rewrites them
        ld a,l
        rrca
        rrca
        rrca
        rrca
        rrca
        and 7                   ; object slot
        ld c,a
        ld hl,dsl_calls
        add a,l
        ld l,a
        ld a,(hl)
        inc (hl)                ; the n-th list of this slot (ovl_dsl reads the counter after it)
        cp 3
        jr c,.n
        ld a,2
.n:     ld b,a
        ld a,c
        add a,a
        add a,c
        add a,b                 ; slot * 3 + n
        add a,a
        add a,a
        add a,a
        ld l,a
        ld h,dsl_rec>>8         ; HL = record
        ld a,(arc_scroll_lo)
        add a,(ix+5)
        ld c,a
        ld a,(arc_scroll_hi)
        adc a,(ix+4)
        and 1
        ld b,a                  ; BC = M
        ld a,(ix+3)
        cp (hl)
        jr nz,.ovl
        inc l
        ld a,c
        cp (hl)
        jr nz,.ovl
        inc l
        ld a,b
        cp (hl)
        jr nz,.ovl
        inc l
        ld a,e
        cp (hl)
        jr nz,.ovl
        inc l
        ld a,d
        cp (hl)
        jr nz,.ovl
        inc l
        ld (hl),1               ; seen
        ld a,1
        ld (dsl_any),a
        ld a,(de)               ; N: IY += 4 N, DE += 2 N + 2
        ld l,a
        ld h,0
        add hl,hl
        push hl
        add hl,hl
        ex de,hl
        add iy,de
        pop de
        add hl,de
        inc hl
        inc hl
        ex de,hl
        ret
.ovl:   ld hl,ovl_dsl
        jp hook_call
        align 256
dsl_static:                     ; map object type -> 1: drawn on plane A (types 5 bunker, $1A/$1B bridges, $22 river bank,
        db 0,0,0,0,0,1,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,1,0,0,0, 0,0,1,1,0,0,0,0     ; $14 area gate, $25 gorge), 2: dugout ($21),
        db 0,2,1,0,0,1,0,0, 3,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0     ; 3: fortress gate ($28)
; bgobj_hit_test / proj_hit_bgobj: the point (x, y) of the object IX against
; the active map structures, from the compact list of the tick (bgo_hitlist:
; y, x, solid box offset and width; the arcade walks its 8 slots, active or
; not, for every moving object and shot). Hit when y - s.y is in [-21,-1]
; and x - s.x + offset < width. Out: A = 1 / NZ hit, A = 0 / Z none; keeps
; IX and C (as the arcade routines), clobbers B, DE, HL.
hook_bgohit:                    ; H = +7 (tentative x), L = +9 (tentative y) of a soldier or the player
        ld a,(bgo_hits)
        or a
        ret z
        ld d,(ix+7)
        ld e,(ix+9)
        jr bgo_hit_scan
hook_projhit:                   ; x = +3, y = +5 of a projectile
        ld a,(bgo_hits)
        or a
        ret z
        ld d,(ix+3)
        ld e,(ix+5)
bgo_hit_scan:
        ld b,a
        ld hl,bgo_hitlist
.s:     ld a,e
        sub (hl)                ; y - s.y
        inc l
        cp 0EBh
        jr c,.n3
        ld a,d
        sub (hl)                ; x - s.x + offset < width
        inc l
        add a,(hl)
        inc l
        cp (hl)
        jr nc,.n1
        ld a,1
        or a
        ret
.n3:    inc l
        inc l
.n1:    inc l
        djnz .s
        xor a
        ret
hook_hit_shots:                 ; queue_hit_shots (hit_check, every even frame): the arcade queues command
        jp ARC_CMD_HIT_SHOTS    ; $0C for its main loop, which the port starves (shots passed through the
                                ; soldiers): the test runs here, at the end of the tick
hook_bg_build:                  ; scroll_build_check: every 64 px the arcade queues command 6
        ld a,1                  ; (bg_build_block) for its main loop, which the port starves: the
        ld (bg_pending),a       ; interrupt handler runs it right after the tick instead
        ret
hook_set_position:              ; map_set_position: load the set, then the original code
        ld hl,ovl_set_position
        call hook_call
        ld ix,071AEh            ; the overwritten first instruction (ld ix,tab_map_events)
        ret

; attract_common, a start button pressed (A = in_system AND 3, not 0): no coins and no
; credit screen, a one-player game at once; START1 (fire / 1) normal, START2 (grenade / 2)
; easy (enemy bullets one speed class slower, see load_params_index)
hook_start:
        and 1
        dec a                   ; START1: 0, START2 alone: $FF
        ld (easy_adj),a
        xor a
        ld (ARC_TWO_PLAYERS),a
        ld hl,(ARC_CMD_RING_RD) ; the commands still queued for the main loop are dropped (the
.drop:  ld a,(hl)               ; title's PRESS FIRE TO START blink came after the clear)
        inc a
        jr z,.empty
        ld (hl),0FFh
        inc l
        ld (hl),0FFh
        inc l                   ; (the ring is the page $E700: it wraps with L)
        jr .drop
.empty: ld (ARC_CMD_RING_RD),hl
        call attract_clear_text        ; the title text goes now (the queued cmd 9 runs late: a
        jp ARC_START_GAME               ; frame of it showed over the cleared background)

; txt sync: Z = the cell is the blank space (code $20, tile bank 0). C = code, the cell
; below the return address on the stack (a code $20 of the banks 1-3 is a graphic tile:
; the COMMANDO logo's $320 was taken for a space and never sent). Keeps BC, DE, HL.
txt_is_space:
        ld a,c
        cp 020h
        ret nz
        push hl
        ld hl,4
        add hl,sp
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a                  ; HL = the cell
        set 2,h
        ld a,(hl)               ; its attribute: b6-7 = tile bank
        pop hl
        and 0C0h
        ret

; (txt_write) text as sprites: the block of the cell (D = row r, E = col c, both 2-29) is
; marked for tsm_update: block (r - 2) / 2 * 14 + (c - 2) / 2, bit b of tsm_dirty
txt_tsm_mark:
        ld a,d
        sub 2
        srl a                   ; rp
        ld l,a
        add a,a
        add a,a
        add a,a
        sub l
        add a,a                 ; 14 rp
        ld l,a
        ld a,e
        sub 2
        srl a                   ; lp
        add a,l
        ld l,a                  ; block
        rrca
        rrca
        rrca
        and 31
        add a,tsm_dirty&255
        ld e,a
        ld d,tsm_dirty>>8       ; (tsm_dirty does not cross a page)
        ld a,l
        and 7
        ld b,a
        ld a,1
        jr z,.set
.sh:    add a,a
        djnz .sh
.set:   ex de,hl
        or (hl)
        ld (hl),a
        ret

; ---- overlay entry points (fixed addresses in the overlay bank, page 2)
ovl_txt_cell    equ 08006h
ovl_bg_cell     equ 08009h
ovl_copy_strip  equ 0800Ch
ovl_bg_clear    equ 0800Fh
ovl_bgobj_all   equ 08018h
ovl_sway        equ 0801Bh
ovl_copy_column equ 0801Eh
ovl_dsl         equ 08021h
ovl_set_position equ 08012h

        ds 0CFF0h-$,0           ; (assembly error if the code is too long)
        ds 16,0
