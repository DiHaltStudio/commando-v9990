; =============================================================================
; Commando for MSX1 + V9990: overlay (ROM bank BANK_OVL, mapped on page 2
; while it runs; the asset banks are mapped on page 1 as needed).
;
; Entry table at $8000 (fixed addresses used by boot and the resident):
;   $8000 ovl_boot_init      $8003 ovl_present     $8006 ovl_txt_cell (HL)
;   $8009 ovl_bg_cell (HL)   $800C ovl_copy_strip  $800F ovl_bg_clear
;   $8012 ovl_set_position $8015 ovl_build (after the arcade tick)
; =============================================================================
        include "common.inc"
        include "../build/port/resident.inc"
        include "../build/port/banks.inc"

        org 08000h
        jp ovl_boot_init
        jp ovl_present
        jp ovl_txt_cell
        jp ovl_bg_cell
        jp ovl_copy_strip
        jp ovl_bg_clear
        jp ovl_set_position
        jp ovl_build
        jp ovl_bgobj_all
        jp ovl_sway
        jp ovl_copy_column
        jp ovl_dsl

; =============================================================================
; V9990 helpers
; =============================================================================
; VRAM write address A:HL (A = bits 18-16). Keeps BC, DE, HL.
v9_setw:
        push af
        xor a
        out (V9_REGS),a
        ld a,l
        out (V9_REGD),a
        ld a,h
        out (V9_REGD),a
        pop af
        out (V9_REGD),a
        ret
; VRAM read address A:HL. Keeps BC, DE, HL.
v9_setr:
        push af
        ld a,3
        out (V9_REGS),a
        ld a,l
        out (V9_REGD),a
        ld a,h
        out (V9_REGD),a
        pop af
        out (V9_REGD),a
        ret
; register A := C
v9_reg:
        out (V9_REGS),a
        ld a,c
        out (V9_REGD),a
        ret
; P#5 VR: catch the leading edge even when the caller arrives during retrace.
ovl_wait_vblank:
        in a,(V9_STAT)
        bit 6,a
        jr nz,ovl_wait_vblank
.active:
        in a,(V9_STAT)
        bit 6,a
        jr z,.active
        ret

; R#8 is shared with the VRAM and sprite controls. Interrupts off on entry.
ovl_display_on:
        call ovl_wait_vblank
ovl_enable_display:
        ld a,0C8h
        out (V9_REGS),a
        in a,(V9_REGD)
        or 080h
        out (V9_REGD),a
        ret
ovl_display_off:
        call ovl_wait_vblank
        ld a,0C8h
        out (V9_REGS),a
        in a,(V9_REGD)
        and 07Fh
        out (V9_REGD),a
        ret
; wait for the command unit
v9_wait:
        in a,(V9_STAT)
        rrca
        jr c,v9_wait
        ret
; HL = address of plane A name table cell (X = E, Y = D), as A:HL with A = 7
pnta_addr:
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
        and 63
        or l
        ld l,a
        add hl,hl
        ld a,h
        add a,VR_PNTA>>8&0FFh
        ld h,a
        ld a,VR_PNTA>>16
        ret
pntb_addr:
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
        and 63
        or l
        ld l,a
        add hl,hl
        ld a,h
        add a,VR_PNTB>>8&0FFh
        ld h,a
        ld a,VR_PNTB>>16
        ret

; Upload a ROM asset to the current VRAM write address: A = first bank,
; HL = offset in that bank (0..$3FFF, multiple of 256), DE = number of
; 256-byte blocks. The banks are mapped on page 1 (left on the last one).
upload_asset:
        ld (p1_cur),a
        ld (BANK_P1),a
        set 6,h
.blk:   ld a,d
        or e
        ret z
        push de
        ld bc,V9_VRAM           ; B = 0: 256 bytes
        otir
        pop de
        dec de
        ld a,h
        cp 080h
        jr nz,.blk
        ld a,(p1_cur)
        inc a
        ld (p1_cur),a
        ld (BANK_P1),a
        ld h,040h
        jr .blk

; =============================================================================
; Boot: V9990 registers, palettes, font, sprite atlas, blank name tables,
; margins, sprite table, runtime variables, set 0. Called with page 2 =
; overlay, page 1 = boot bank; returns with page 1 = boot bank.
; =============================================================================
ovl_boot_init:
        ld a,2
        out (V9_SYS),a          ; soft reset
        xor a
        out (V9_SYS),a
        ld hl,v9_regs_init
.r:     ld a,(hl)
        cp 0FFh
        jr z,.rdone
        inc hl
        ld c,(hl)
        inc hl
        call v9_reg
        jr .r
.rdone: ld a,7
        out (V9_INT),a
        ; ---- palette: 64 entries
        ld a,14
        out (V9_REGS),a
        xor a
        out (V9_REGD),a
        ld a,BANK_PAL           ; (a bank of its own: the overlay is full)
        ld (p1_cur),a
        ld (BANK_P1),a
        ld hl,04000h
        call ovl_wait_vblank
        ld bc,192*256+V9_PAL
        otir
        ; ---- font (plane A patterns from FONT_BASE) and the sprite atlas
        ld a,(VR_PATA+FONT_Y*128)>>16
        ld hl,(VR_PATA+FONT_Y*128)&0FFFFh
        call v9_setw
        ld a,BANK_FONT
        ld de,FONT_BYTES/256
        ld hl,0
        call upload_asset
        ; the decoration rows of the font again, kept raw for load_set
        ld a,VR_DECORAW>>16
        ld hl,VR_DECORAW&0FFFFh
        call v9_setw
        ld a,BANK_FONT+DECO_FONT_OFF/16384
        ld de,DECO_ROWS*4
        ld hl,DECO_FONT_OFF&03FFFh
        call upload_asset
        ld a,(VR_PATA+ATLAS_Y*128)>>16
        ld hl,(VR_PATA+ATLAS_Y*128)&0FFFFh
        call v9_setw
        ld a,BANK_ATLAS
        ld de,ATLAS_BYTES/256
        ld hl,0
        call upload_asset
        ; ---- name table A: blank, margins (columns 0-1, 30-31) opaque black
        ld a,VR_PNTA>>16
        ld hl,VR_PNTA&0FFFFh
        call v9_setw
        ld d,64
.ra:    ld e,0
.ca:    ld a,e
        cp 2
        jr c,.black
        cp 30
        jr nc,.black
        ld a,PATA_BLANK&255
        out (V9_VRAM),a
        ld a,PATA_BLANK>>8
        out (V9_VRAM),a
        jr .na
.black: ld a,PATA_BLACK&255
        out (V9_VRAM),a
        ld a,PATA_BLACK>>8
        out (V9_VRAM),a
.na:    inc e
        ld a,e
        cp 64
        jr nz,.ca
        dec d
        jr nz,.ra
        ; ---- SPAT and the two staging images: all disabled
        ld a,VR_STG_A>>16
        ld hl,VR_STG_A&0FFFFh
        call v9_setw
        ld bc,128+128+SPAT_LIMIT
.sp:    ld a,216
        out (V9_VRAM),a
        xor a
        out (V9_VRAM),a
        out (V9_VRAM),a
        ld a,010h
        out (V9_VRAM),a
        dec bc
        ld a,b
        or c
        jr nz,.sp
        ; ---- runtime variables
        ld hl,RT_VARS
        ld de,RT_VARS+1
        ld bc,03Fh
        ld (hl),0
        ldir
        ld a,0FFh
        ld (cur_set),a
        ld hl,spr_owner
        ld de,spr_owner+1
        ld bc,511
        ld (hl),0FFh
        ldir
        ld hl,spr_stamp
        ld de,spr_stamp+1
        ld bc,255
        ld (hl),0
        ldir
        ld hl,spr_blk_of        ; (its low part also holds the flight / pause variables)
        ld de,spr_blk_of+1
        ld bc,255
        ld (hl),0
        ldir
        ; Execute the per-entry renderer from internal turbo R RAM. Fixed slots
        ; have no cache stamps. The dynamic cache starts at spr_stamp+SPR_DYNAMIC.
        ld hl,spat_fast_rom
        ld de,spr_stamp
        ld bc,spat_fast_end-spat_fast_rom
        ldir
        ; spat_keep uses only the first SPR_FIX bytes of spr_owner as scratch.
        ; The rest of its fixed-slot owner area can hold the cache-hit loop.
        ld hl,spr_lookup_rom
        ld de,spr_owner+SPR_FIX
        ld bc,spr_lookup_end-spr_lookup_rom
        ldir
        ld hl,hud_cells
        ld de,hud_cells+1
        ld bc,28*4+28-1
        ld (hl),0FFh
        ldir
        ld hl,txt_blank_map
        ld de,txt_blank_map+1
        ld bc,127
        ld (hl),0
        ldir
        ld hl,ovl_cache
        ld de,ovl_cache+1
        ld bc,96*4-1
        ld (hl),0
        ldir
        xor a
        ld (ovl_count),a
        ld hl,0FFFFh
        ld (lookup_key),hl      ; no background combo cached
        ld hl,bgo_rec
        ld de,bgo_rec+1
        ld bc,9*8-1
        ld (hl),0
        ldir
        ld hl,dsl_rec
        ld de,dsl_rec+1
        ld bc,24*8-1
        ld (hl),0
        ldir
        ld hl,dsl_calls
        ld de,dsl_calls+1
        ld bc,9-1
        ld (hl),0
        ldir                    ; dsl_calls, dsl_any
        ld hl,txt_row_tab
        ld de,txt_row_tab+1
        ld bc,1023
        ld (hl),0
        ldir
        xor a
        ld (hud_count),a
        ld (hud_presented),a
        ld a,2
        ld (spr_hand),a
        ; ---- set 0 (title: map position 0), blank plane B
        xor a
        call load_set
        call ovl_bg_clear
        ; ---- display on
        call ovl_display_on
        ld a,BANK_BOOT
        ld (p1_cur),a
        ld (BANK_P1),a
        ret

v9_regs_init:
        db 6,005h               ; R#6: P1
        db 7,000h               ; R#7: NTSC (60 Hz), non-interlaced
        db 8,002h               ; R#8: display off
        db 9,000h               ; R#9: no interrupts yet
        db 13,001h              ; R#13: plane A palette block 1, plane B block 0
        db 15,000h              ; R#15: backdrop = colour 0
        db 16,000h
        db 17,000h,18,000h      ; SCAY
        db 19,000h,20,000h      ; SCAX
        db 21,000h,22,000h      ; SCBY
        db 23,000h,24,000h      ; SCBX
        db 25,000h              ; R#25: sprite generator at $00000
        db 27,000h
        db 0FFh

; =============================================================================
; Asset sets: palette block 0, plane B patterns and the lookup bank
; =============================================================================
; A = set 0-7. Display off during the upload.
load_set:
        ld (cur_set),a
        push af
        ld a,i                  ; P/V = IFF2: interrupts enabled?
        di
        ex af,af'               ; AF' keeps the interrupt state (whole transfer with interrupts off)
        pop af
        push af
        add a,a
        add a,a
        add a,a                 ; * SET_BANKS (8)
        add a,BANK_SET0
        ld (set_bank),a
        ld a,(pal_hold)
        or a
        jr nz,.keep             ; the display stays on (palette at the first present of the new map)
        call ovl_display_off
        ld a,14
        out (V9_REGS),a
        xor a
        out (V9_REGD),a         ; palette pointer = 0 (block 0)
        ld a,(set_bank)
        add a,SET_PAL_BANKOFF   ; the bank holding the palette and the index
        ld (p1_cur),a
        ld (BANK_P1),a
        ld hl,SET_PAL_OFF+04000h
        ld bc,96*256+V9_PAL     ; blocks 0 (plane B) and 1 (plane A)
        otir
.keep:  ld a,(pal_hold)         ; the next set preloaded during the flight (pre_step): only the
        or a                    ; switch of the halves, the fixed sprites and the decorations
        jr z,.nopre             ; copied remain
        ld a,(pre_state)
        cp 4
        jr nz,.nopre
        ld a,(pre_set)
        ld hl,cur_set
        cp (hl)
        jr nz,.nopre
        xor a
        ld (pre_state),a
        ld a,(patb_hi)
        xor 8
        ld (patb_hi),a
        pop af
        call spat_keep
        call spr_commit
        jp .convd
.nopre: xor a
        ld (pre_state),a        ; (a preload for another set, or none: discarded)
        ld a,(patb_hi)          ; the patterns go to the other half of the plane B area: the
        xor 8                   ; shown cells keep theirs until the new map is presented
        ld (patb_hi),a
        rrca
        rrca
        rrca
        add a,VR_PATB>>16
        ld hl,VR_PATB&0FFFFh
        call v9_setw
        pop af
        ld l,a
        ld h,0
        add hl,hl
        ld de,set_sizes
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)               ; DE = 256-byte blocks of the patterns
        ld a,(set_bank)
        ld hl,0
        call upload_asset
        ; fixed sprite cells -> SGT slots 0..SPR_FIX-1 (without blanking: the fixed slots on
        ; screen are copied to dynamic slots first)
        ld a,(pal_hold)
        or a
        call nz,spat_keep
        ld a,VR_SGT>>16
        ld hl,VR_SGT&0FFFFh
        call v9_setw
        ld a,(set_bank)
        add a,SET_SPR_BANKOFF
        ld de,SET_SPR_BYTES/256
        ld hl,0
        call upload_asset
        ld a,(pal_hold)         ; a load without blanking: into VR_DECOTMP, copied at the switch
        or a                    ; (the old patterns stay with the old colours until then)
        jr z,.conv
        ld a,VR_DECOTMP>>16
        ld hl,VR_DECOTMP&0FFFFh
        call deco_convert_to
        jr .convd
.conv:  call deco_convert
.convd:
        ld hl,0FFFFh
        ld (lookup_key),hl      ; the cached background combo was the old set's
        ld (zone_lo),hl         ; no zone: the next present looks the position up
        ld a,l
        ld (zone_var),a
        xor a
        ld (port_pal_on),a      ; block 0 = the area's
        ; dynamic slots: all free
        ld hl,spr_owner+2*SPR_DYNAMIC
        ld de,spr_owner+2*SPR_DYNAMIC+1
        ld bc,2*(240-SPR_DYNAMIC)-1
        ld (hl),0FFh
        ldir
        ld a,(tsm_on)           ; the text blocks of the pickup flight keep their slots (the
        or a                    ; helicopter's pieces took them: both vanished after the load)
        call nz,tsm_reserve
        ld a,(pal_hold)
        or a
        jr z,.hold
        xor a
        ld (spat_ready),a       ; (a staging image built before the load names the old fixed slots)
.hold:  ld a,1                  ; the display stays off until a frame of the new map is presented
        ld (disp_hold),a        ; (display_release): turned on here, 2-3 frames showed the old
        ex af,af'               ; scroll, sprites and palettes over the new patterns
        ret po                  ; interrupts were off
        ei
        ret

; =============================================================================
; Flight preload (pre_step, one slice per build, interrupts on between slices): while the
; helicopter flies the next set (set + 1) is loaded in pieces of 2.6-3.6 ms of VRAM access:
; its plane B patterns into the free half of the pattern area, its fixed sprite cells into
; VR_SPRTMP and its decorations (converted through its LUTs) into VR_DECOTMP. load_set then
; only copies the sprite cells (spr_commit): the 0.6 s load with interrupts off (a frozen
; picture, the sound stuck on its last note) became one frame.
; =============================================================================
pre_step:
        ld a,(pre_state)
        or a
        jr nz,.run
        ld a,(tsm_on)           ; the pickup flight only
        or a
        ret z
        ld a,(arc_game_state+1)
        cp 6
        ret nz
        ld a,(pal_hold)
        or a
        ret nz
        ld a,(cur_set)
        cp 3
        jr z,.start
        cp 7
        ret nz
.start: inc a
        and 7
        ld (pre_set),a
        ld a,(patb_hi)
        xor 8
        rrca
        rrca
        rrca
        add a,VR_PATB>>16
        ld (us_vram+2),a        ; the free half
        ld hl,VR_PATB&0FFFFh
        ld (us_vram),hl
        ld a,(pre_set)
        add a,a
        ld l,a
        ld h,0
        ld de,set_sizes
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (us_left),de
        call pre_bank           ; A = the set's first bank
        ld (us_bank),a
        ld hl,04000h
        ld (us_hl),hl
        ld a,1
        ld (pre_state),a
        ret
.run:   cp 4
        ret nc
        cp 3
        jr z,.deco
        call upl_slice
        ret nz
        ld a,(pre_state)
        inc a
        ld (pre_state),a
        cp 2
        ret nz
        ld a,VR_SPRTMP>>16      ; the sprite cells next
        ld (us_vram+2),a
        ld hl,VR_SPRTMP&0FFFFh
        ld (us_vram),hl
        call pre_bank
        add a,SET_SPR_BANKOFF
        ld (us_bank),a
        ld hl,04000h
        ld (us_hl),hl
        ld hl,SET_SPR_BYTES/256
        ld (us_left),hl
        xor a
        ld (dc_line),a
        jp set_idx_bank
.deco:  call pre_deco
        ld a,(dc_line)
        cp DECO_ROWS*8
        ret c
        ld a,4
        ld (pre_state),a
        ret

; A = first bank of the set being preloaded
pre_bank:
        ld a,(pre_set)
        add a,a
        add a,a
        add a,a
        add a,BANK_SET0
        ret

; 2 blocks of the asset job (us_*) to VRAM. Z = nothing left (finished).
upl_slice:
        ld de,(us_left)
        ld a,d
        or e
        ret z
        ld a,i
        push af
        di
        ld a,(us_vram+2)
        ld hl,(us_vram)
        call v9_setw
        ld a,(us_bank)
        ld (p1_cur),a
        ld (BANK_P1),a
        ld hl,(us_hl)
        ld de,(us_left)
        ld a,2                  ; blocks per slice
.b:     ex af,af'
        ld bc,V9_VRAM
        otir                    ; 256 bytes (B = 0)
        dec de
        ld a,h
        cp 080h
        jr nz,.nb
        ld a,(p1_cur)
        inc a
        ld (p1_cur),a
        ld (BANK_P1),a
        ld h,040h
.nb:    ex af,af'
        dec a
        jr z,.end
        ld b,a
        ld a,d
        or e
        ld a,b
        jr nz,.b
.end:   ld (us_hl),hl
        ld (us_left),de
        ld a,(p1_cur)
        ld (us_bank),a
        ld hl,(us_vram)         ; 512 bytes on
        ld a,(us_vram+2)
        ld de,512
        add hl,de
        jr nc,.nc
        inc a
.nc:    ld (us_vram),hl
        ld (us_vram+2),a
        pop af
        jp po,.ndi
        ei
.ndi:   call set_idx_bank
        ld de,(us_left)
        ld a,d
        or e
        ret                     ; Z when finished

; 4 lines of the decoration conversion of the preloaded set into VR_DECOTMP
pre_deco:
        ld a,i
        push af
        di
        ld a,(dc_line)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; 128 * line
        push hl
        ld de,VR_DECOTMP&0FFFFh
        add hl,de
        ld a,VR_DECOTMP>>16
        call v9_setw
        pop hl
        ld a,VR_DECORAW>>16
        call v9_setr
        call pre_bank
        add a,SET_PAL_BANKOFF
        ld (p1_cur),a
        ld (BANK_P1),a
        ld a,(dc_line)          ; the row's 4 LUT page bytes: SET_SEG_OFF + 4 * (line / 8)
        rrca
        rrca
        rrca
        and 01Fh
        add a,a
        add a,a
        ld l,a
        ld h,0
        ld de,SET_SEG_OFF+04000h
        add hl,de
        ld b,4
.l:     push bc
        call deco_line
        pop bc
        djnz .l
        ld a,(dc_line)
        add a,4
        ld (dc_line),a
        pop af
        jp po,.ndi
        ei
.ndi:   jp set_idx_bank

; the staged fixed sprite cells -> SGT slots 0..SPR_FIX-1 (one LMMM; the cells on screen were
; moved to dynamic slots by spat_keep first)
spr_commit:
        call v9_wait
        ld a,32
        out (V9_REGS),a
        xor a
        out (V9_REGD),a         ; R#32 SX = 512 (the $40000- half of the image space)
        ld a,2
        out (V9_REGD),a
        ld a,(VR_SPRTMP-VR_PATB)/128&255
        out (V9_REGD),a         ; R#34 SY
        ld a,(VR_SPRTMP-VR_PATB)/128>>8
        out (V9_REGD),a
        xor a
        out (V9_REGD),a         ; R#36 DX = 0
        out (V9_REGD),a
        out (V9_REGD),a         ; R#38 DY = 0 (the SGT)
        out (V9_REGD),a
        out (V9_REGD),a         ; R#40 NX = 256
        ld a,1
        out (V9_REGD),a
        ld a,SPR_FIX
        out (V9_REGD),a         ; R#42 NY = SPR_FIX lines (16 slots of 16x16 per 16 lines)
        xor a
        out (V9_REGD),a
        out (V9_REGD),a         ; R#44 ARG
        ld a,00Ch
        out (V9_REGD),a         ; R#45 LOP: D = S
        ld a,0FFh
        out (V9_REGD),a         ; R#46 WM
        xor a                   ; R#47: protect plane B for this plane A destination
        out (V9_REGD),a
        ld a,52
        out (V9_REGS),a
        ld a,040h
        out (V9_REGD),a         ; R#52: LMMM
        jp v9_wait

; plane A decorations of the set (set_bank): see the comment inside. Interrupts off (the VRAM
; read and write pointers stream).
deco_convert:
        ld a,(VR_PATA+32*OVL_BASE)>>16
        ld hl,(VR_PATA+32*OVL_BASE)&0FFFFh
deco_convert_to:                ; (A:HL = where the converted rows go)
        call v9_setw
        ; plane A decorations: the raw pens kept at VR_DECORAW through the set's LUTs (a 256-byte
        ; page per palette variant and sprite palette, two pens per byte) -> the patterns from
        ; OVL_BASE. One decoration = 32 bytes of each of the 8 lines of its row; the set's
        ; segment table (SET_SEG_OFF) gives the LUT page per decoration.
        ld a,(set_bank)
        add a,SET_PAL_BANKOFF
        ld (p1_cur),a
        ld (BANK_P1),a
        ld a,VR_DECORAW>>16
        ld hl,VR_DECORAW&0FFFFh
        call v9_setr
        ld hl,SET_SEG_OFF+04000h
        ld a,DECO_ROWS
.drow:  push af
        ld b,8
.dline: push bc
        call deco_line
        pop bc
        dec b
        jp nz,.dline
        ld de,4
        add hl,de
        pop af
        dec a
        jp nz,.drow
        ret

; one line of a decoration row: HL = the row's 4 LUT page bytes (kept); the VRAM read and write
; pointers stream (4 x 32 bytes)
deco_line:
        push hl
        ld b,4
.dseg:  ld a,(hl)
        add a,(SET_LUT_OFF+04000h)>>8
        ld d,a
        inc hl
        push bc
        ld c,V9_VRAM
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        in a,(c)
        ld e,a
        ld a,(de)
        out (c),a
        pop bc
        dec b
        jp nz,.dseg
        pop hl
        ret

; bytes of plane B patterns per set (from banks.inc)
set_sizes:
        dw SET0_BYTES/256,SET1_BYTES/256,SET2_BYTES/256,SET3_BYTES/256,SET4_BYTES/256,SET5_BYTES/256,SET6_BYTES/256,SET7_BYTES/256

; map the index bank of the current set on page 1
set_idx_bank:
        ld a,(set_bank)
        add a,SET_PAL_BANKOFF
        ld (p1_cur),a
        ld (BANK_P1),a
        ret

; Background combo lookup: HL = BG_CODE cell. Returns DE = pattern base
; (13 bits) of (code, attribute); the blank tile combo if unknown.
; Page 1 := the set's index bank. Uses A, BC, HL.
bg_lookup:
        call set_idx_bank
bg_lookup_nb:                   ; (page 1 already holds the set's index)
        ld c,(hl)               ; code low
        set 2,h
        ld a,(hl)               ; attribute
        res 2,h
        ld b,a
        ld hl,(lookup_key)      ; the same combo as the last time (runs of the same tile)
        or a
        sbc hl,bc
        jr nz,.new
        ld de,(lookup_last)
        ret
.new:   ld (lookup_key),bc
        and 0C0h
        rlca
        rlca                    ; code bits 8-9
        ld l,c
        ld h,a
        add hl,hl
        ld de,SET_IDX_OFF+04000h
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,d
        or e
        jr z,.unknown
        ld hl,SET_IDX_OFF+04000h
        add hl,de               ; HL = list (offsets are relative to the index start)
        ld a,b
        and 03Fh
        ld c,a
.l:     ld a,(hl)
        cp 0FFh
        jr z,.unknown
        cp c
        jr z,.found
        inc hl
        inc hl
        inc hl
        jr .l
.found: inc hl
        ld e,(hl)
        inc hl
        ld a,(patb_hi)
        add a,(hl)
        ld d,a                  ; + the half of the plane B pattern area in use
        ld (lookup_last),de
        ret
.unknown:
        ld hl,dbg_unknown
        inc (hl)
        ld bc,(lookup_key)
        ld (dbg_bg_key),bc
        ld a,(patb_hi)          ; combo 0 = the most frequent one (not the blank; visible as a wrong tile)
        ld d,a
        ld e,0
        ld (lookup_last),de
        ret

; Font lookup: C = char low, B = attribute (b6-7 char high bits, b0-3 palette).
; Returns DE = plane A pattern (the direct table: 2 banks, palettes 0-7 and
; 8-15). Page 1 := that bank. Uses A, HL.
font_lookup:
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
        rlca                    ; char bits 8-9
        ld h,a
        ld a,b
        and 7
        rlca
        rlca
        or h                    ; (pal & 7) << 2 | char bits 8-9: word index bits 15-8 before the doubling
        ld h,a
        ld l,c
        add hl,hl               ; byte address of the word (char low << 1, carry into H)
        set 6,h                 ; page 1
        ld e,(hl)
        inc hl
        ld d,(hl)
        ret

; =============================================================================
; Text layer: one cell to plane A. HL = TXT_CODE cell ($D000-$D7FF).
; Plane A scrolls with plane B (SCAY = SCBY), so the row is computed from the
; current map position. Rows 0-1 and 30-31 (the margins) are not written.
; =============================================================================
ovl_txt_cell:
        ex de,hl                ; HL = the cell (passed in DE by the resident)
        ld c,(hl)               ; code
        set 2,h
        ld b,(hl)               ; attribute
        res 2,h
        ld a,h
        and 3
        rlca
        rlca
        rlca                    ; bits 0-1 -> 3-4
        ld d,a
        ld a,l
        rlca
        rlca
        rlca
        and 7
        or d
        ld d,a                  ; D = row r = (addr & $3FF) >> 5
        ld a,l
        and 31
        ld e,a                  ; E = col c
        ld a,d
        cp 2
        ret c
        cp 30
        ret nc
        push de
        call font_lookup        ; DE = pattern
        ex de,hl                ; HL = pattern
        pop de
        push hl
        call txt_row_base       ; A := plane row of column E
        ld e,d                  ; X = r
        ld d,a                  ; Y
        call pnta_addr
        di
        call v9_setw
        pop hl
        ld a,l
        out (V9_VRAM),a
        ld a,h
        out (V9_VRAM),a
        ret

; A = plane A row of text column E (0-31). Plane A does not scroll (SCAY = 0):
; text cell column c is at screen line 248 - 8c, V9990 line 248 - 8c - CROP_TOP,
; plane row (31 - CROP_TOP/8 - c) & 63 = (28 - c) & 63.
txt_row_base:
        push hl
        ld a,(txt_shift_top)
        cp e
        ld a,31-CROP_TOP/8
        sub e
        jr c,.nosh
        ld hl,txt_shift
        sub (hl)
.nosh:  and 63
        pop hl
        ret

; =============================================================================
; Background: one cell to plane B. HL = BG_CODE cell ($D800-$DBFF).
; Column C = (addr & $3FF) >> 5 -> plane rows (30 - 2C) & 63 and +1;
; tile t = addr & 31 -> plane columns 2t, 2t+1.
; =============================================================================
ovl_bg_cell:
        ld a,(pal_hold)         ; a load without blanking: the old cells stay until the switch
        dec a
        cp 2
        ret c
ovl_bg_put:
        ex de,hl                ; HL = the cell
        push hl
        call bg_lookup          ; DE = pattern base
        pop hl
        ld a,h
        and 3
        rlca
        rlca
        rlca
        ld c,a
        ld a,l
        rlca
        rlca
        rlca
        and 7
        or c                    ; A = C
        add a,a
        ld c,a                  ; 2C
        ld a,30
        sub c
        and 63
        ld b,a                  ; B = row
        ld a,(bgx_or)
        or l
        and 31
        add a,a                 ; 2t (+ 32: the right half)
        push de
        ld e,a
        ld d,b
        push de
        call pntb_addr
        di
        call v9_setw
        pop de
        pop bc                  ; BC = base
        ld a,c
        out (V9_VRAM),a
        ld a,b
        out (V9_VRAM),a
        inc bc
        ld a,c
        out (V9_VRAM),a
        ld a,b
        out (V9_VRAM),a
        inc d                   ; next row
        push bc
        call pntb_addr
        call v9_setw
        pop bc
        inc bc
        ld a,c
        out (V9_VRAM),a
        ld a,b
        out (V9_VRAM),a
        inc bc
        ld a,c
        out (V9_VRAM),a
        ld a,b
        out (V9_VRAM),a
        ret

; =============================================================================
; map_copy_strip_bg replacement: 4 BG columns x 16 tiles from the tile buffer
; (ix+$0C/$0D, high first) to BG_CODE/BG_ATTR from (ix+$0E/$0F) and to plane B.
; Pointers updated like the original (rings $F000-$F3FF and $D800-$DBFF).
; =============================================================================
ovl_copy_strip:
        ld c,4
.column:
        push bc
        xor a
        ld (bg_half),a
        call ovl_copy_column    ; tiles 0-7 (and the pointers)
        ld a,1
        ld (bg_half),a
        call ovl_copy_column    ; tiles 8-15
        pop bc
        dec c
        jr nz,.column
        ret

; one column of the strip: 16 tiles from the tile buffer (ix+$0C/$0D) to the
; BG shadow (ix+$0E/$0F) and plane B; the pointers advance as the arcade's
; map_copy_strip_bg does (rings $F000-$F3FF and $D800-$DBFF)
ovl_copy_column:
        ld a,(bg_half)
        and 1
        jr nz,.second
        ld h,(ix+0Ch)
        ld l,(ix+0Dh)
        ld d,(ix+0Eh)
        ld e,(ix+0Fh)
        ld b,16
.tile:  ld a,(hl)
        ld (de),a
        inc hl
        ld a,(hl)
        set 2,d
        ld (de),a
        res 2,d
        inc hl
        inc de
        djnz .tile
        push hl
        push de
        ex de,hl
        ld bc,-16
        add hl,bc               ; HL = column base (BG_CODE cell of tile 0)
        ld (sc_colbase),hl
        xor a
        call strip_column       ; plane B rows of tiles 0-7 (8-15 on the next step)
        pop de
        pop hl
        ex de,hl
        ld bc,16
        add hl,bc               ; skip tiles 16-31
        ex de,hl
        ld a,h
        and 0F3h
        ld (ix+0Ch),a
        ld (ix+0Dh),l
        ex de,hl
        ld a,h
        and 0DBh
        ld (ix+0Eh),a
        ld (ix+0Fh),l
        ret
.second:
        ld hl,(sc_colbase)
        ld a,8
        jp strip_column

; HL = BG_CODE cell of tile 0 of a column, A = first tile (0 or 8): write the
; 2 plane B rows of 8 tiles (16 entries each). The 8 combos are looked up
; once (sc_bases), both rows come from them.
strip_column:
        ld (sc_first),a
        ld a,(pal_hold)         ; a load without blanking: the old cells stay until the switch
        dec a
        cp 2
        ret c
        ld a,h
        and 3
        rlca
        rlca
        rlca
        ld c,a
        ld a,l
        rlca
        rlca
        rlca
        and 7
        or c                    ; column C
        add a,a
        ld c,a
        ld a,30
        sub c
        and 63
        ld (sc_row),a
        ld a,(sc_first)
        add a,l
        ld l,a                  ; the first tile's cell (the column is 32-aligned)
        push ix                 ; (the caller's streamer block)
        ld ix,sc_bases
        call set_idx_bank
        ld b,8
.look:  push bc
        push hl
        call bg_lookup_nb       ; DE = base (uses A, HL)
        ld (ix+0),e
        ld (ix+1),d
        inc ix
        inc ix
        pop hl
        inc hl
        pop bc
        djnz .look
        ; row 0 (top halves): base, base + 1; row 1 (bottom halves): base + 2, base + 3
        ld a,(sc_row)
        ld d,a
        ld a,(sc_first)
        add a,a
        ld e,a                  ; cell x = 2 * tile
        push de
        call pntb_addr
        di
        call v9_setw
        ld hl,sc_bases
        ld c,V9_VRAM
        ld b,8
.r0:    ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        out (c),e
        out (c),d
        inc de
        out (c),e
        out (c),d
        djnz .r0
        pop de
        ld a,d
        inc a
        and 63
        ld d,a
        call pntb_addr
        call v9_setw
        ld hl,sc_bases
        ld c,V9_VRAM
        ld b,8
.r1:    ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        inc de
        inc de
        out (c),e
        out (c),d
        inc de
        out (c),e
        out (c),d
        djnz .r1
        pop ix
        ret

; =============================================================================
; bg_clear replacement: shadow := $F8 / 0, plane B := the blank combo.
; =============================================================================
ovl_bg_clear:
        ld hl,BG_CODE
        ld de,BG_CODE+1
        ld bc,03FFh
        ld (hl),0F8h
        ldir
        ld bc,0400h
        ld (hl),0
        ldir
        ld hl,BG_CODE           ; its cell: code $F8, attribute 0
        call bg_lookup          ; DE = base
        push de
        ld a,VR_PNTB>>16
        ld hl,VR_PNTB&0FFFFh
        di
        call v9_setw
        pop de
        ld h,64                 ; rows
.row:   ld b,32                 ; cells per row, 2 per tile
        ld c,V9_VRAM
.c:     out (c),e
        out (c),d
        inc de
        out (c),e
        out (c),d
        dec de
        djnz .c
        ; the second plane row of the same tiles uses base+2
        ld b,32
        inc de
        inc de
.c2:    out (c),e
        out (c),d
        inc de
        out (c),e
        out (c),d
        dec de
        djnz .c2
        dec de
        dec de
        dec h
        dec h
        jr nz,.row
        ; the plane A decorations go too: a record kept across the blank showed its cells
        ; again (a palm tree quad over the area-clear picture), and so did cells a missed
        ; clear had left; none is drawn until the map is placed again (map_set_position):
        ; a build interrupted by this tick redrew the open gate over the picture
        ld a,1
        ld (deco_block),a
        jp deco_wipe_all

; =============================================================================
; map_set_position hook: the asset set of the new map position
; =============================================================================
ovl_set_position:
        ld hl,(arc_game_state)  ; L = state, H = sub-state. A queued cmd 9 (text cleared) runs in
        ld de,00603h            ; the main loop while the new set loads: the old text (letters
        or a                    ; re-placed by the jump of P) showed over the new picture. It is
        sbc hl,de               ; cleared now as cmd 9 will at: the end of an area clear (3, 6:
        jr nz,.n36              ; area_clear_done queues it next, with the picture on screen; not
        ld a,(IO_SCROLLY_HI)    ; at the end of the pickup flight: CONGRATULATION stays over the
        and 1                   ; next area as in the arcade), the start of a life (3, 1:
        jr nz,.clr
        jr .nclr
.n36:
        ld hl,(arc_game_state)  ; queued just before, the HUD redrawn after it) and the title
        ld de,00103h            ; (1, 0: after the boot screen's cmd 9; attract_wait_end has
        or a                    ; already cleared it on the next rounds)
        sbc hl,de
        jr z,.clr
        ld hl,(arc_game_state)
        ld de,00001h
        or a
        sbc hl,de
        jr nz,.nclr
.clr:   call area_text_clear
.nclr:  xor a
        ld (deco_block),a       ; the map is placed again: decorations drawn
        ld a,(ARC_HELI)         ; (not the helicopter's, entries 6-40: its body vanished for the
        or a                    ; jump to the next area at the end of the pickup flight)
        jr nz,.nohide
        ld hl,SPRITERAM+12*4+2  ; the structures' sprite entries (12-78, both bases) hidden: a
        ld de,4                 ; debris animation may have been cut (map_clear_bgobj frees the slots)
        ld b,66
.hide:  ld (hl),0
        add hl,de
        djnz .hide
.nohide:
        dec l                   ; entry 78 is also the player's (and the title soldier's head,
        ld a,(hl)               ; whose position the arcade sets once): hidden only when it
        and 0F0h                ; holds structure debris (bank 2, palette 3)
        cp 0B0h
        jr nz,.keep78
        inc l
        ld (hl),0
.keep78:
        ld hl,(arc_pl_map_pos)
        ld a,h                  ; bits 11-13 -> area in the map, bit 14 -> map
        and 03Fh
        cp 020h
        jr c,.inmap
        ld a,01Fh               ; extra strips after area 4 / 8: stay on the last set
.inmap: rrca
        rrca
        rrca
        and 3
        ld c,a
        ld a,h
        and 040h
        rrca
        rrca
        rrca
        rrca                    ; bit 14 -> bit 2
        or c
        ld hl,cur_set
        cp (hl)
        ret z
        ld c,a
        ld a,(IO_SCROLLY_HI)    ; the area-clear picture is still shown (the arcade places the
        and 1                   ; next area's map before it ends): the set loads after it, else
        jr z,.now               ; the picture's cells showed the new set's patterns (sand dots,
        ld a,c                  ; with the picture's palette: cyan noise)
        inc a
        ld (set_pending),a
        ret
.now:   ld hl,(arc_game_state)  ; the pickup flight (3, 6) reaching the next area: its last
        ld de,00603h            ; strips are the next map's first ones, the same picture: the
        or a                    ; set loads without blanking (the screen went black for the load)
        sbc hl,de
        jr nz,.blank
        ld a,1
        ld (pal_hold),a
.blank: ld a,c
        jp load_set

; cmd_clear_text's work (rows 0-31, columns 0-29 := space, attribute 0) and the
; plane A text places blanked
area_text_clear:
        ld hl,TXT_CODE
        ld c,32
.r:     ld b,30
.c:     ld (hl),020h
        set 2,h
        ld (hl),0
        res 2,h
        inc l
        djnz .c
        inc hl                  ; columns 30-31 (score lines) kept
        inc hl
        dec c
        jr nz,.r
        ld hl,hud_blk_dirty+14  ; the bottom HUD band (columns 0-1) is composed again
        ld b,14
.d:     ld (hl),1
        inc hl
        djnz .d
        ld a,1
        ld (hud_dirty),a
        jp txt_blank_all

; =============================================================================
; Frontmost text for READY, GAME OVER and the lap-end pickup flight. Plane A
; also carries map decorations and some arcade sprites have priority over it.
; Compose 2x2 text-cell blocks into sprite slots 212-239 and emit these before
; the scenery and actors. Only the pickup message moves above the bottom HUD.
; =============================================================================
TSM_SLOT0       equ 212
; slots 212-239 kept from the sprite cache (an owner no key matches)
tsm_reserve:
        ld hl,spr_owner+2*TSM_SLOT0
        ld b,56
.o:     ld (hl),0FEh
        inc hl
        djnz .o
        ret
tsm_update:
        ld a,(arc_game_state)
        cp 3
        jr nz,.off
        ld a,(IO_SCROLLY_HI)
        and 1
        jr nz,.off
        ld a,(arc_game_state+1)
        cp 2                    ; PLAYER n / READY at the checkpoint
        jr z,.on
        cp 8                    ; PLAYER n / GAME OVER over the last scene
        jr z,.on
        cp 6
        jr z,.on
        cp 3                    ; the helicopter of a life start (PLAYER 1 READY under it, which is
        jr nz,.off              ; drawn in front of plane A): the text in front of it too
        ld a,(ARC_HELI)
        or a
        jr z,.off
.on:    ld a,1
        jr .set
.off:   xor a
.set:   ld hl,tsm_on
        cp (hl)
        jp z,.run
        ld (hl),a
        or a
        jr z,.leave
        ; entering: the plane A text cells blanked (txt_follow's first pass), every block dirty,
        ; the slots reserved (an owner no key matches)
        call txt_blank_all
        ld hl,tsm_dirty
        ld b,25
.d:     ld (hl),0FFh
        inc hl
        djnz .d
        ld hl,tsm_slot
        ld b,28
.s:     ld (hl),0FFh
        inc hl
        djnz .s
        ld hl,tsm_last          ; no slot holds text yet, no block shown
        ld b,28
.l:     ld (hl),0FFh
        inc hl
        djnz .l
        ld hl,tsm_shown
        ld b,25
.z:     ld (hl),0
        inc hl
        djnz .z
        call tsm_reserve
        jr .run
.leave: ld hl,spr_owner+2*TSM_SLOT0     ; the slots back to the cache, the text back on plane A
        ld b,56
.f:     ld (hl),0FFh
        inc hl
        djnz .f
        ld a,(arc_scroll_hi)
        xor 040h
        ld (txt_pos+1),a        ; a far position: txt_follow re-places every cell
        ret
.run:   ld a,(tsm_on)
        or a
        ret z
        ld a,(build_no)         ; the reserved slots look used by every build (never evicted)
        ld hl,spr_stamp+TSM_SLOT0
        ld b,28
.st:    ld (hl),a
        inc hl
        djnz .st
        ; compose the dirty blocks, 8 per byte: a clean byte costs one test (the loop over the
        ; 196 blocks took ~28% of the time of the flight and the drop-off)
        ld hl,tsm_dirty
        ld c,0                  ; block of the byte's bit 0
        ld de,0                 ; its row pair, line pair (block = 14 rp + lp)
.byte:  ld a,(hl)
        or a
        jr z,.skip
        ld (hl),0               ; clean: its blocks are composed now
        push hl
        ld h,a                  ; its bits
        ld l,8
.bit:   srl h
        jr nc,.next
        push hl
        push de
        push bc
        ld a,c
        cp 196
        call c,tsm_block        ; C = block, D = rp, E = lp
        pop bc
        pop de
        pop hl
.next:  inc c
        inc e
        ld a,e
        cp 14
        jr c,.nw
        ld e,0
        inc d
.nw:    dec l
        jr nz,.bit
        pop hl
        jr .adv
.skip:  ld a,c
        add a,8
        ld c,a
        ld a,e
        add a,8
        cp 14
        jr c,.sw
        sub 14
        inc d
.sw:    ld e,a
.adv:   inc l                   ; (tsm_dirty does not cross a page)
        ld a,c
        cp 200
        jr c,.byte
        ret

; C = block: compose it into its slot (allocated / freed by its content)
tsm_block:                      ; C = block, D = its row pair rp, E = its line pair lp
        ld a,d
        ld (tsm_cur),a
        ld a,e
        ld (tsm_cur+1),a
        ld a,d                  ; rp
        add a,a
        add a,2                 ; r = 2 rp + 2
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; 32 r
        ld a,e
        add a,a
        add a,3                 ; c + 1 = 2 lp + 3 (the upper line)
        or l
        ld l,a
        ld a,h
        or TXT_CODE>>8
        ld h,a                  ; HL = TL cell (r, c + 1)
        ld (hud_hl),hl
        ; empty (4 spaces)?
        ld a,(hl)
        dec hl
        and (hl)                ; (r, c)
        ld de,32
        add hl,de
        and (hl)                ; (r + 1, c)
        inc hl
        and (hl)                ; (r + 1, c + 1)
        cp 020h                 ; (all $20: AND = $20; a code other than space differs)
        ld a,0
        jr nz,.text
        ld hl,(hud_hl)
        ld a,(hl)
        cp 020h
        jr nz,.text
        dec hl
        ld a,(hl)
        cp 020h
        jr nz,.text
        ld de,32
        add hl,de
        ld a,(hl)
        cp 020h
        jr nz,.text
        inc hl
        ld a,(hl)
        cp 020h
        jr nz,.text
        ; empty: its slot hidden (the composed text stays there for the next blink)
        call tsm_bit
        and (hl)
        ret z                   ; not shown
        ld a,b
        cpl
        and (hl)
        ld (hl),a
        call .find
        ret nz
        ld (hl),0FFh
        ret
.text:  call tsm_bit
        or (hl)
        ld (hl),a               ; shown
        call .find              ; in a slot already: composed again only when its text changed
        jr nz,.kept
        call tsm_sig_cmp
        ret z
        jr .comp
.kept:  ld hl,tsm_slot          ; a free slot still holding this block's text (the blink): shown
        ld de,tsm_last
        ld b,28
.k:     ld a,(hl)
        inc a
        jr nz,.kn
        ld a,(de)
        cp c
        jr z,.kgot
.kn:    inc hl
        inc e
        djnz .k
        ld hl,tsm_slot          ; else a free slot holding no text, else any free slot
        ld de,tsm_last
        ld b,28
.e:     ld a,(de)
        and (hl)
        inc a
        jr z,.got
        inc hl
        inc e
        djnz .e
        ld hl,tsm_slot
        ld b,28
.fr:    ld a,(hl)
        cp 0FFh
        jr z,.got
        inc hl
        djnz .fr
        call tsm_bit            ; none: the block stays hidden
        cpl
        and (hl)
        ld (hl),a
        ret
.kgot:  ld (hl),c
        call .xy
        call tsm_sig_cmp
        ret z                   ; the text composed there: no compose
        jr .comp
.got:   ld (hl),c
        call .xy
.comp:  ld a,l
        sub tsm_slot&255
        ld e,a
        ld d,tsm_last>>8
        ld a,c
        ld (de),a               ; the slot holds this block's text
        call tsm_sig_put
        ld a,e
        add a,TSM_SLOT0
        ld c,a                  ; slot
        ld hl,(hud_hl)
        ld de,0000h
        call hud_compose.cell
        ld hl,(hud_hl)
        ld de,32
        add hl,de
        ld de,0800h
        call hud_compose.cell
        ld hl,(hud_hl)
        dec hl
        ld de,0008h
        call hud_compose.cell
        ld hl,(hud_hl)
        ld de,31
        add hl,de
        ld de,0808h
        jp hud_compose.cell
; HL = the slot's tsm_slot entry: its place (tsm_rp, tsm_lp) := the block's. Keeps BC, HL.
.xy:    ld a,l
        sub tsm_slot&255
        add a,tsm_rp&255
        ld e,a
        ld d,tsm_rp>>8
        ld a,(tsm_cur)
        ld (de),a
        ld a,e
        add a,tsm_lp-tsm_rp
        ld e,a
        ld a,(tsm_cur+1)
        ld (de),a
        ret
; C = block -> Z and HL = its tsm_slot entry when it has one
.find:  ld hl,tsm_slot
        ld b,28
.fl:    ld a,(hl)
        cp c
        ret z
        inc hl
        djnz .fl
        or 1                    ; NZ
        ret

; C = block -> HL = its byte of tsm_shown, A = B = its bit
tsm_bit:
        ld a,c
        rrca
        rrca
        rrca
        and 31
        add a,tsm_shown&255
        ld l,a
        ld h,tsm_shown>>8
        ld a,c
        and 7
        ld b,a
        ld a,1
        jr z,.d
.s:     add a,a
        djnz .s
.d:     ld b,a
        ret

; The text a slot was composed with (codes and attributes of its 4 cells, 8 bytes per slot
; at VR_TSMSIG): HL = the slot's tsm_slot entry, (hud_hl) = the block's top-left cell.
; tsm_sig_cmp: Z when the cells hold that text. Both keep BC, DE, HL.
tsm_sig_cmp:
        push hl
        push de
        push bc
        call tsm_sig_addr
        ld b,a
        ld a,i
        push af
        di
        ld a,b
        call v9_setr
        ld hl,(hud_hl)
        call .c2
        jr nz,.out
        ld de,32
        add hl,de
        call .c2
        jr nz,.out
        ld de,-33
        add hl,de
        call .c2
        jr nz,.out
        ld de,32
        add hl,de
        call .c2
.out:   ld b,0
        jr z,.eq
        inc b
.eq:    pop af
        jp po,.ndi
        ei
.ndi:   ld a,b
        or a
        pop bc
        pop de
        pop hl
        ret
.c2:    in a,(V9_VRAM)
        cp (hl)
        ret nz
        set 2,h
        in a,(V9_VRAM)
        cp (hl)
        res 2,h
        ret
tsm_sig_put:
        push hl
        push de
        push bc
        call tsm_sig_addr
        ld b,a
        ld a,i
        push af
        di
        ld a,b
        call v9_setw
        ld hl,(hud_hl)
        call .p2
        ld de,32
        add hl,de
        call .p2
        ld de,-33
        add hl,de
        call .p2
        ld de,32
        add hl,de
        call .p2
        pop af
        jp po,.ndi
        ei
.ndi:   pop bc
        pop de
        pop hl
        ret
.p2:    ld a,(hl)
        out (V9_VRAM),a
        set 2,h
        ld a,(hl)
        out (V9_VRAM),a
        res 2,h
        ret
tsm_sig_addr:                   ; HL = tsm_slot entry -> A:HL = its signature
        ld a,l
        sub tsm_slot&255
        add a,a
        add a,a
        add a,a
        ld l,a
        ld h,(VR_TSMSIG>>8)&255
        ld a,VR_TSMSIG>>16
        ret

; the blocks with a slot: SPAT entries (in front, block 1), moved down so the lowest line
; holding text sits at line 184 (above the HUD band at 196, below the helicopter)
tsm_emit:
        ld a,(tsm_on)
        or a
        ret z
        ld hl,tsm_slot          ; lowest line pair with a block
        ld de,tsm_lp
        ld b,28
        ld c,0FFh
.lo:    ld a,(hl)
        inc a
        jr z,.ln
        ld a,(de)
        cp c
        jr nc,.ln
        ld c,a
.ln:    inc hl
        inc e
        djnz .lo
        ld a,c
        cp 0FFh
        ret z
        ; lowest line c = 2 lp + 2 is at line 224 - 8c; wanted 184: shift = 8c - 40 = 16 lp - 24
        add a,a
        add a,a
        add a,a
        add a,a
        sub 24
        ld b,a
        ld a,(arc_game_state+1) ; (the life start's message stays where the arcade puts it)
        cp 6
        ld a,b
        jr z,.sh
        xor a
.sh:    ld (tsm_shift),a
        ld hl,tsm_slot
        ld b,28
        ld c,TSM_SLOT0
.em:    ld a,(hl)
        cp 0FFh
        jr z,.en
        push hl
        push bc
        ld a,c
        sub TSM_SLOT0-(tsm_rp&255)
        ld l,a
        ld h,tsm_rp>>8
        ld b,(hl)               ; rp
        add a,tsm_lp-tsm_rp
        ld l,a
        ld a,(hl)               ; lp; the block's top line: c + 1 = 2 lp + 3 at 224 - 8(c + 1)
        add a,a
        add a,a
        add a,a
        add a,a                 ; 16 lp
        ld e,a
        ld a,224-24
        sub e                   ; 200 - 16 lp
        ld hl,tsm_shift
        add a,(hl)              ; the block's line
        dec a                   ; SPAT Y = line - 1
        out (V9_VRAM),a
        ld a,c
        out (V9_VRAM),a         ; slot
        ld a,b
        add a,a
        add a,2                 ; r
        add a,a
        add a,a
        add a,a                 ; x = 8r
        out (V9_VRAM),a
        ld a,040h               ; block 1, in front
        out (V9_VRAM),a
        ld hl,spat_cnt
        inc (hl)
        pop bc
        pop hl
.en:    inc hl
        inc c
        djnz .em
        ret

; every placed text cell's plane A place blanked (txt_follow's first pass)
txt_blank_all:
        ld hl,txt_row_tab
.cl:    ld a,(hl)
        or a
        jr z,.cn
        ld (hl),0
        push hl
        dec a
        ld d,a
        ld a,l
        rlca
        rlca
        rlca
        and 7
        ld e,a
        ld a,h
        and 3
        rlca
        rlca
        rlca
        or e
        ld e,a
        call pnta_addr
        ld c,a
        ld a,i
        push af
        di
        ld a,c
        call v9_setw
        ld a,PATA_BLANK&255
        out (V9_VRAM),a
        ld a,PATA_BLANK>>8
        out (V9_VRAM),a
        pop af
        jp po,.cdi
        ei
.cdi:   pop hl
.cn:    inc hl
        ld a,h
        cp (txt_row_tab>>8)+4
        jr c,.cl
        ld a,1
        ld (ovl_refresh),a
        ld (vram_moved),a
        ret

; After the area-clear picture: the set postponed by map_set_position, then plane B
; drawn again from the arcade's background (its cells were placed with the old set).
set_pending_load:
        ld a,(set_pending)
        or a
        ret z
        ld a,(IO_SCROLLY_HI)
        and 1
        ret nz
        ld a,(set_pending)
        dec a
        ld hl,cur_set
        cp (hl)
        jr z,.done
        call load_set
        call bg_redraw_all
.done:  xor a
        ld (set_pending),a
        ret

; plane B := the arcade's background shadow (BG_CODE / BG_ATTR), every cell, with the
; current set's patterns
bg_redraw_all:
        ld a,i
        push af
        ld de,BG_CODE
.c:     push de
        call ovl_bg_cell
        pop de
        inc de
        ld a,d
        cp (BG_CODE>>8)+4
        jr c,.c
        pop af
        ret po
        ei
        ret

; =============================================================================
; present: called from the interrupt with page 2 = overlay, interrupts off.
; =============================================================================
; In the interrupt: only what must happen in the blanking (prepared data).
; While ovl_build is running (it was interrupted) the previous SPAT is kept.
ovl_present:
        ld hl,frame_no
        inc (hl)
        ld a,(in_build)
        or a
        jr nz,.keep             ; a build in progress: the previous frame stays (scroll and sprites together)
        in a,(V9_STAT)
        and 040h                ; VR: present_scroll writes the scroll
        ld (pres_vr),a          ; b6 = entry VR, b0 = fresh palette window acquired this IRQ
        call present_scroll
        call present_spat_clear
        call spat_copy
        call present_portrait
        call display_release    ; (before present_zone: a switch without blanking writes blocks 0-1
        call present_zone       ; and the zone its slots 8-15 in the same retrace)
.keep:  jp read_input

; The portrait, map switch, display release and zone colours form one publication.
; At most 144 palette bytes and a bounded zone-table scan follow the first edge.
; Waiting separately for each would hold the audio ISR across multiple frames.
present_blank:
        ld a,(pres_vr)
        bit 0,a
        jr z,.wait
        in a,(V9_STAT)
        bit 6,a
        ret nz
.wait:  ld a,(pres_vr)
        or 1
        ld (pres_vr),a
        jp ovl_wait_vblank

; the display off since a set load: on at the first present, in the retrace, of a build made
; after the load (its scroll, sprites and palettes are the new map's)
display_release:
        ld a,(pal_hold)
        cp 2
        jr z,bg_switch
        cp 4
        jr z,bg_switch
        ld a,(disp_hold)
        cp 2
        ret nz
        ld a,(pres_vr)
        and 040h
        ret z
        xor a
        ld (disp_hold),a
        call present_blank
        jp ovl_enable_display

; Switch after a load without blanking (pal_hold), in the retrace: 2 = the next map is in
; plane B's right half (bg_redraw_half): the new set's block 0 and block 1 entries 0-7
; (8-15: present_zone) and SCBX = 256 together (drawn cell by cell on screen, the cells
; showed as noise against the old palette for 2 frames); 4 = the left half drawn again:
; back to SCBX = 0.
bg_switch:
        ld a,(pres_vr)
        and 040h
        ret z
        ld a,(pal_hold)
        cp 4
        jr z,.back
        ld a,14
        out (V9_REGS),a
        xor a
        out (V9_REGD),a
        ld a,(p1_cur)
        push af
        call set_idx_bank
        ld hl,SET_PAL_OFF+04000h
        call present_blank
        ld bc,72*256+V9_PAL
        otir
        pop af
        ld (p1_cur),a
        ld (BANK_P1),a
        call deco_copy          ; the decorations' patterns converted for the new set
        ld a,3
        ld (pal_hold),a
        ld a,1
        jr .scbx
.back:  xor a
        ld (pal_hold),a
.scbx:  ld (bx_half),a
        rrca
        rrca
        rrca                    ; 1 -> 32 (SCBX 256)
        ld c,a
        ld a,24
        jp v9_reg

; VR_DECOTMP -> the decoration patterns at OVL_BASE: one LMMM of DECO_ROWS x 8 lines of 256
; pixels (in the interrupt: not waited for, the next command waits)
deco_copy:
        call v9_wait
        ld a,32
        out (V9_REGS),a
        xor a
        out (V9_REGD),a         ; R#32 SX = 512: X bit 9 selects the plane B half ($40000-) of
        ld a,2                  ; the P1 image space (128 bytes per line in each half)
        out (V9_REGD),a
        ld a,(VR_DECOTMP-VR_PATB)/128&255
        out (V9_REGD),a         ; R#34 SY
        ld a,(VR_DECOTMP-VR_PATB)/128>>8
        out (V9_REGD),a
        xor a
        out (V9_REGD),a         ; R#36 DX = 0
        out (V9_REGD),a
        ld a,(VR_PATA+32*OVL_BASE)/128&255
        out (V9_REGD),a         ; R#38 DY
        ld a,(VR_PATA+32*OVL_BASE)/128>>8
        out (V9_REGD),a
        xor a
        out (V9_REGD),a         ; R#40 NX = 256
        inc a
        out (V9_REGD),a
        ld a,DECO_ROWS*8
        out (V9_REGD),a         ; R#42 NY
        xor a
        out (V9_REGD),a
        out (V9_REGD),a         ; R#44 ARG
        ld a,00Ch
        out (V9_REGD),a         ; R#45 LOP: D = S
        ld a,0FFh
        out (V9_REGD),a         ; R#46 WM
        xor a                   ; R#47: protect plane B for this plane A destination
        out (V9_REGD),a
        ld a,52
        out (V9_REGS),a
        ld a,040h
        out (V9_REGD),a         ; R#52: LMMM
        ret

; plane B from the arcade's background, map tiles 0-15 only (16-31: the area-clear picture),
; A = 0: to their own columns, 16: to the right half (columns 32-63)
; one slice of the same (24 cells): NZ = more to come
bg_redraw_step:
        ld (bgx_or),a
        ld a,i
        push af
        ld de,(brh_de)
        ld a,d
        or e
        jr nz,.go
        ld de,BG_CODE
.go:    ld b,24
.c:     ld a,d
        cp (BG_CODE>>8)+4
        jr nc,.fin
        ld a,e
        and 16
        jr nz,.n
        push bc
        push de
        call ovl_bg_put
        pop de
        pop bc
        dec b
        jr z,.sl
.n:     inc de
        jr .c
.sl:    inc de
        ld (brh_de),de
        ld c,1
        jr .out
.fin:   ld de,0
        ld (brh_de),de
        ld c,0
.out:   xor a
        ld (bgx_or),a
        pop af
        jp po,.ndi
        ei
.ndi:   ld a,c
        or a
        ret
bg_redraw_half:
        ld (bgx_or),a
        ld a,i
        push af
        ld de,BG_CODE
.c:     ld a,e
        and 16
        jr nz,.n
        push de
        call ovl_bg_put
        pop de
.n:     inc de
        ld a,d
        cp (BG_CODE>>8)+4
        jr c,.c
        xor a
        ld (bgx_or),a
        pop af
        ret po
        ei
        ret

; load_set without blanking: the SPAT on screen names fixed slots that the new set's cells
; replace (the helicopter of the pickup flight broke up for the load). Each fixed slot it
; names is copied to a free dynamic slot (LMMM, all dynamic slots are free after the load)
; and its entries repointed; past the free slots the entries are disabled. Interrupts off.
spat_keep:
        ld hl,spr_owner         ; fixed slot -> its copy ($FF none): the owner bytes of the fixed
        ld de,spr_owner+1       ; slots (read by nothing else)
        ld bc,SPR_FIX-1
        ld (hl),0FFh
        ldir
        ld a,SPR_DYNAMIC
        ld (keep_next),a
        ld a,VR_SPAT>>16
        ld hl,VR_SPAT&0FFFFh
        call v9_setr
        call v9_setw            ; read and write pointers step together
        ld b,128
.e:     push bc
        in a,(V9_VRAM)
        ld d,a                  ; Y
        in a,(V9_VRAM)
        ld e,a                  ; slot
        in a,(V9_VRAM)
        ld c,a                  ; X
        in a,(V9_VRAM)
        ld b,a                  ; attribute
        bit 4,b
        jr nz,.out              ; disabled
        ld a,e
        cp SPR_FIX
        jr nc,.out              ; a dynamic, text or HUD slot
        cp HELI_SLOTS
        jr c,.out               ; the helicopter: the same cells in the sets of the flight
        ld l,a
        ld h,spr_owner>>8
        ld a,(hl)
        cp 0FFh
        jr nz,.have
        push hl
        call keep_alloc
        pop hl
        jr c,.hide
        ld (hl),a
        push de
        push bc
        ld c,a
        call lmmm_slot          ; slot E -> slot C
        ld a,c
        pop bc
        pop de
.have:  ld e,a
        jr .out
.hide:  set 4,b
.out:   ld a,d
        out (V9_VRAM),a
        ld a,e
        out (V9_VRAM),a
        ld a,c
        out (V9_VRAM),a
        ld a,b
        out (V9_VRAM),a
        pop bc
        djnz .e
        jp v9_wait              ; the copies done before the fixed cells are replaced

; A = a dynamic slot not used by the last two builds (the SPAT on screen may name the ones
; of the previous build: the rotor's), stamped with this build; CF = none left (up to 211
; while the text blocks hold 212-239). Keeps BC, DE.
keep_alloc:
        push bc
        ld a,(tsm_on)
        dec a
        and 28
        add a,212
        ld c,a
        ld a,(build_no)
        ld b,a
        ld a,(keep_next)
        ld l,a
        ld h,spr_stamp>>8
.f:     ld a,l
        cp c
        jr nc,.none
        ld a,b
        sub (hl)
        cp 2
        jr nc,.ok
        inc l
        jr .f
.ok:    ld (hl),b
        ld a,l
        inc a
        ld (keep_next),a
        ld a,l
        pop bc
        or a
        ret
.none:  pop bc
        scf
        ret

; LMMM: SGT slot E -> SGT slot C (16x16). No interrupt change (load_set).
lmmm_slot:
        call v9_wait
        ld a,32
        out (V9_REGS),a
        ld a,e
        and 15
        rlca
        rlca
        rlca
        rlca
        out (V9_REGD),a         ; R#32 SX
        xor a
        out (V9_REGD),a
        ld a,e
        and 0F0h
        out (V9_REGD),a         ; R#34 SY
        xor a
        out (V9_REGD),a
        ld a,c
        and 15
        rlca
        rlca
        rlca
        rlca
        out (V9_REGD),a         ; R#36 DX
        xor a
        out (V9_REGD),a
        ld a,c
        and 0F0h
        out (V9_REGD),a         ; R#38 DY
        xor a
        out (V9_REGD),a
        jp lmmm_16

; hide_sprites ran (hook_hide): the live entries following the HUD are
; disabled now and a staging image built before it dropped
present_spat_clear:
        ld a,(spat_clear)
        or a
        ret z
        xor a
        ld (spat_clear),a
        ld (spat_ready),a
        ld a,(hud_presented)
        ld e,a
        add a,a
        add a,a
        ld l,a
        ld h,(VR_SPAT>>8)&255
        ld a,VR_SPAT>>16
        call v9_setw
        ld a,SPAT_LIMIT
        sub e
        ld b,a
.c:     ld a,216
        out (V9_VRAM),a
        xor a
        out (V9_VRAM),a
        out (V9_VRAM),a
        ld a,010h
        out (V9_VRAM),a
        djnz .c
        ret

; the area-clear picture (IO_SCROLLY_HI = 1) has a block 0 palette of its own in the set
; bank (its tiles are converted with it); the area's comes back after it
present_portrait:
        ld a,(IO_SCROLLY_HI)
        and 1
        ld hl,port_pal_on
        cp (hl)
        ret z
        ld (hl),a
        ld hl,SET_PAL_OFF+04000h
        or a
        jr z,.pal
        ld hl,SET_PORT_OFF+04000h
.pal:   ld a,(cur_set)
        inc a
        ret z
        ld a,(p1_cur)
        push af
        ld a,(set_bank)
        add a,SET_PAL_BANKOFF
        ld (p1_cur),a
        ld (BANK_P1),a
        ld a,14
        out (V9_REGS),a
        xor a
        out (V9_REGD),a         ; palette pointer: entry 0 (block 0)
        call present_blank
        ld bc,48*256+V9_PAL
        otir
        pop af
        ld (p1_cur),a
        ld (BANK_P1),a
        ret

; plane A palette zone of the presented map position (build_pos): when it leaves the
; current zone, the set's zone table (start position, variant; $FFFF end) gives the new
; one, and a new variant's 8 colours go to block 1 entries 8-15 (palette entries 24-31):
; the decorations of zones never on the same screen have colours of their own.
present_zone:
        ld a,(pal_hold)         ; a load without blanking: the old zone colours until the switch
        dec a
        cp 2
        ret c
        ld hl,(build_pos)
        ld a,h
        and 03Fh
        ld h,a                  ; HL = P (position in the map)
        ld de,(zone_lo)
        or a
        sbc hl,de
        add hl,de
        jr c,.look              ; P < first position
        ld de,(zone_hi)
        or a
        sbc hl,de
        add hl,de
        ret c                   ; P < end: same zone
.look:  ld a,(cur_set)
        inc a
        ret z                   ; no set loaded
        ex de,hl                ; DE = P
        ld a,(p1_cur)
        push af
        ld a,(set_bank)
        add a,SET_PAL_BANKOFF
        ld (p1_cur),a
        ld (BANK_P1),a
        ld hl,SET_ZONE_OFF+04000h
.z:     ld c,(hl)
        inc hl
        ld b,(hl)               ; BC = start of zone i
        inc hl
        ld a,(hl)               ; its variant
        inc hl
        push af
        push bc
        ld c,(hl)
        inc hl
        ld b,(hl)               ; BC = start of zone i+1
        dec hl                  ; HL = zone i+1
        ld a,e
        sub c
        ld a,d
        sbc a,b
        jr c,.found             ; P < start of zone i+1
        pop bc
        pop af
        jr .z
.found: ld (zone_hi),bc
        pop bc
        ld (zone_lo),bc
        pop af                  ; A = variant
        ld hl,zone_var
        cp (hl)
        jr z,.done
        ld (hl),a
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld e,l
        ld d,h
        add hl,hl
        add hl,de               ; 24 * variant
        ld de,SET_VAR_OFF+04000h
        add hl,de
        ld a,14
        out (V9_REGS),a
        ld a,24*4
        out (V9_REGD),a         ; palette pointer: entry 24 (block 1, index 8)
        call present_blank
        ld bc,24*256+V9_PAL
        otir
.done:  pop af
        ld (p1_cur),a
        ld (BANK_P1),a
        ret

; After the arcade tick, interrupts enabled (off around the V9990 port
; sequences): sprites and HUD for the next frame
ovl_build:
        ld a,1
        ld (in_build),a
        ld hl,build_no
        inc (hl)
        call set_pending_load   ; a set postponed during the area-clear picture
        ld a,(pal_hold)         ; after a switch without blanking (the right half shown): the
        cp 3                    ; left half from the arcade's background
        jr nz,.p1
        xor a
        call bg_redraw_step     ; (in slices: the arcade's tick goes on meanwhile)
        jr nz,.redo
        ld a,4
        ld (pal_hold),a
        xor a
        ld (deco_tmp),a         ; plane A holds the new decorations now
        jr .redo
.p1:    dec a                   ; 1: the build whose present switches (the right half is drawn:
        jr nz,.redo             ; brh_done) composes its decoration sprites from the new set's
        ld a,(brh_done)         ; decorations (VR_DECOTMP): composed from plane A (the old set's),
        or a                    ; a palm tree was pale for the frames after the switch
        jr z,.redo
        ld a,1
        ld (deco_tmp),a
        ld hl,spr_owner+2*SPR_DYNAMIC+1 ; the cached ones (key bit 15) composed again
        ld b,240-SPR_DYNAMIC
.dk:    ld a,(hl)
        cp 0FEh                 ; ($FE: a text slot, $FF: free)
        jr nc,.dkn
        rlca
        jr nc,.dkn
        ld (hl),0FFh
        dec l
        ld (hl),0FFh
        inc l
.dkn:   inc l
        inc l
        djnz .dk
.redo:
        call pre_step           ; the next set loads in slices during the pickup flight
        call tsm_update         ; frontmost message sprites
        call txt_follow         ; a jump of the map position (life / area start): the text cells again
        ld a,(sway_hit)         ; the structures follow the sway codes while the helicopter hovers
        ld hl,sway_on
        cp (hl)
        jr z,.sway
        ld (hl),a
        ld a,1
        ld (bgo_dirty),a        ; sway state changed: every structure record is checked
.sway:  xor a
        ld (sway_hit),a
        ld a,(hud_dirty)
        or a
        call nz,hud_update
        call build_spat
        ld hl,ovl_sweep_ctr     ; the sweeps of the plane A records, one kind every 4th build
        inc (hl)
        ld a,(hl)
        and 3
        jr z,.sw0
        dec a
        jr z,.sw1
        dec a
        jr nz,.swdone
        call dsl_sweep          ; static structures (bunkers, bridges...) no longer drawn: cells cleared
        jr .swdone
.sw1:   call bgo_sweep          ; map structures (palm trees, rocks) no longer drawn
        jr .swdone
.sw0:   call ovl_sweep          ; sprite-entry decorations no longer drawn
.swdone:
        call deco_scroll_wipe
        ld hl,ovl_refresh
        ld a,(hl)
        or a
        jr z,.norefresh
        ld (hl),0
        call ovl_redraw         ; text erased: the decoration cells under it come back
        call bgo_redraw
        call dsl_redraw
.norefresh:
        ld a,(arc_scroll_hi)
        ld h,a
        ld a,(arc_scroll_lo)
        ld l,a
        ld (build_pos),hl       ; presented with this SPAT
        ld a,(disp_hold)
        or a
        jr z,.held
        ld a,2
        ld (disp_hold),a        ; a frame of the new map is ready: the next present turns the display on
.held:  ld a,(pal_hold)         ; a load without blanking: the builds of the next map (out of
        dec a                   ; the extra strips of the flight, positions $2000-$3FFF of the
        jr nz,.ph               ; map) draw it into the right half in slices; the build after
        ld a,(deco_tmp)         ; the last slice is presented with the new palette
        or a
        jr z,.draw
        xor a
        ld (brh_done),a
        ld (brh_go),a
        inc a
        ld a,2                  ; (the decorations' new patterns: an LMMM in the switch's retrace)
        ld (pal_hold),a
        jr .ph
.draw:  ld a,(brh_go)
        or a
        jr nz,.sl
        ld a,(build_pos+1)      ; first slice: the position of this build is in the extra strips
        and 03Fh
        cp 020h
        jr nc,.ph
        ld a,1
        ld (brh_go),a
.sl:    ld a,16
        call bg_redraw_step
        jr nz,.ph
        ld a,1
        ld (brh_done),a
.ph:    xor a
        ld (in_build),a
        ret

; scroll registers from the map position of the last build, only inside the vertical
; retrace (a late interrupt keeps the previous scroll: one frame of lag
; instead of a torn picture)
present_scroll:
        in a,(V9_STAT)
        bit 6,a                 ; VR: vertical retrace
        ret z
        ld hl,(build_pos)       ; the map position of the SPAT being shown
        ld a,CROP_TOP
        sub l
        ld l,a
        ld a,0
        sbc a,h
        and 1
        ld h,a                  ; HL = (CROP_TOP - P) & 511
        ld (scby_cur),hl
        ld a,21
        out (V9_REGS),a
        ld a,l
        out (V9_REGD),a         ; R#21 SCBY low
        ld a,h
        out (V9_REGD),a         ; R#22 SCBY high
        ld a,17
        out (V9_REGS),a
        ld a,l
        out (V9_REGD),a         ; R#17 SCAY low: plane A (text and decorations) scrolls with the map
        ld a,h
        out (V9_REGD),a         ; R#18 SCAY high
        ld a,(IO_SCROLLY_HI)
        ld hl,bx_half
        or (hl)
        and 1
        rlca
        rlca
        rlca
        rlca
        rlca                    ; 1 -> 32 = 256 >> 3
        ld c,a
        ld a,24
        out (V9_REGS),a
        ld a,c
        out (V9_REGD),a         ; R#24 SCBX bits 8-3
        ret

; The text cells are placed on plane A by the map position P at the time of
; the write (the arcade's text layer does not scroll). A jump of P (the
; start of a life or an area; the main loop may have written text just
; before it, e.g. PLAYER 1 READY on a fast CPU) leaves them on rows that are
; off the screen: every non-blank cell is written again at the new rows
; (txt_write clears the old place and raises ovl_refresh for the
; decorations under it).
; The V9990 shows 212 lines (V9990 lines 0-211 = arcade lines 24-235): text
; columns 0-3 (arcade lines 224-255: CAPCOM, COPYRIGHT 1985, ALL RIGHTS
; RESERVED, CREDIT) would be cut, or under the bottom HUD band (columns 0-1,
; sprites at lines 196-211, shown during a game only). While any of them holds
; text (columns 2-3 only during a game: 0-1 are the lives and grenades), the
; text goes 3 rows (24 lines) up: the bottom block (columns 0-3) alone when
; columns 4-6 are free, else every row; columns 0-1 go to plane A too and the
; band hides. Checked every 8th build; a change re-places all the text cells.
txt_follow:
        ld a,(build_no)
        and 7
        jp nz,.pos
        ld hl,(arc_game_state)
        ld a,l
        dec a
        jr nz,.scan_footer
        ld a,h
        cp 3                    ; attract ranking: layout set before drawing, including the
        jp z,.pos               ; frames while the main loop is still writing the footer
.scan_footer:
        ld a,l                  ; the lowest text column holding text among 0-3 (2-3 during a
        cp 3                    ; game: 0-1 are the HUD band, lives and grenades)
        ld e,0
        jr nz,.st
        ld e,2
.st:    ld c,4                  ; C = lowest column found (4: none)
        ld hl,TXT_CODE+2*32
        ld b,28                 ; rows 2-29
.s:     push hl
        ld a,l
        or e
        ld l,a
.s2:    ld a,(hl)
        cp 020h
        jr z,.s3
        ld a,l
        and 31
        cp c
        jr nc,.s3
        ld c,a
.s3:    inc l
        ld a,l
        and 31
        cp 4
        jr c,.s2
        pop hl
        ld a,l
        add a,32
        ld l,a
        jr nc,.s4
        inc h
.s4:    djnz .s
        ld a,3                  ; rows to move up: 3 - lowest column (column 0 at line 224 -> 200)
        sub c
        jr nc,.sh
        xor a
.sh:    ld c,a
        ld d,0
        or a
        jr z,.set
        ld d,3                  ; the bottom block (columns 0-3) alone when the columns it moves
        ld hl,TXT_CODE+2*32+4   ; onto (4 .. 3 + shift) are free (a sprite beside a text, like the
        ld b,28                 ; credit screen's soldier, stays beside it); else every row
.f:     push hl
        push bc
        ld b,c
.f2:    ld a,(hl)
        cp 020h
        jr nz,.busy
        inc l
        djnz .f2
        pop bc
        pop hl
        ld a,l
        add a,32
        ld l,a
        jr nc,.f3
        inc h
.f3:    djnz .f
        jr .set
.busy:  pop bc
        pop hl
        ld d,31
.set:   call txt_down_scan
        ld e,a
        ld a,(txt_down)
        cp e
        jr nz,.chg
        ld a,(txt_shift)
        cp c
        jr nz,.chg
        ld a,(txt_shift_top)
        cp d
        jr z,.pos
.chg:   ld a,e
        ld (txt_down),a
        ld a,c
        ld (txt_shift),a
        ld a,d
        ld (txt_shift_top),a
        ld a,1
        ld (hud_spat_dirty),a   ; the bottom band hides while the text is moved up
        ld (hud_dirty),a
        jr .jump                ; every text cell to its new row
.pos:   ld hl,(txt_pos)
        ld a,(arc_scroll_hi)
        ld d,a
        ld a,(arc_scroll_lo)
        ld e,a
        ex de,hl
        or a
        sbc hl,de               ; P - txt_pos
        jr nc,.abs
        ld a,h
        cpl
        ld h,a
        ld a,l
        cpl
        ld l,a
        inc hl
.abs:   ld a,h
        or a
        jr nz,.jump
        ld a,l
        cp 64
        ret c
.jump:  ld a,(arc_scroll_hi)
        ld h,a
        ld a,(arc_scroll_lo)
        ld l,a
        ld (txt_pos),hl
        ; pass 1: every placed text cell's old place blanked (in one pass the old place of a
        ; cell could be the new place of a cell already moved: letters went missing)
        ld hl,txt_row_tab
.cl:    ld a,(hl)
        or a
        jr z,.cn
        ld (hl),0
        push hl
        dec a
        ld d,a                  ; the old row
        ld a,l
        rlca
        rlca
        rlca
        and 7
        ld e,a
        ld a,h
        and 3
        rlca
        rlca
        rlca
        or e
        ld e,a                  ; X = row r of the cell
        call pnta_addr
        ld c,a
        ld a,i
        push af
        di
        ld a,c
        call v9_setw
        ld a,PATA_BLANK&255
        out (V9_VRAM),a
        ld a,PATA_BLANK>>8
        out (V9_VRAM),a
        pop af
        jp po,.cdi
        ei
.cdi:   pop hl
.cn:    inc hl
        ld a,h
        cp (txt_row_tab>>8)+4
        jr c,.cl
        ld a,1
        ld (ovl_refresh),a      ; decoration cells under the old places come back
        ld (vram_moved),a
        ; pass 2: every text cell written at its new place
        ld hl,TXT_CODE
.c:     ld a,(hl)
        cp 020h
        jr nz,.w
        set 2,h
        ld a,(hl)
        res 2,h
        and 0C0h                ; a code $20 of the tile banks 1-3 is graphics (the logo)
        jr z,.n
.w:     push hl
        call txt_write          ; (resident: clears the old place, writes the new one)
        pop hl
.n:     inc hl
        ld a,h
        cp (TXT_CODE>>8)+4      ; (parenthesised: sjasm evaluates + before >>)
        jr c,.c
        ret

; Text columns 27-29 (arcade lines 16-39) are at V9990 lines 0-15 under the top
; HUD band (1UP, TOP SCORE: sprites), e.g. the name entry's TIMER: during a game,
; while they hold text and the cells 2 columns lower are free (or move too),
; they go 2 rows (16 lines) down, below the band. Out: A = rows (0 or 2).
; Keeps BC, D.
txt_down_scan:
        ld a,(arc_game_state)
        cp 3
        jr nz,.no
        push bc
        push de
        ld hl,TXT_CODE+2*32+29
        ld b,28                 ; rows 2-29
        ld de,0                 ; D: text in columns 27-29, E: a cell would land on text
.r:     ld c,0                  ; C bit i: text in column 25 + i
.r2:    ld a,(hl)
        cp 020h
        scf                     ; carry: text
        jr nz,.r3
        ccf
.r3:    rl c
        dec l
        ld a,l
        and 31
        cp 25
        jr nc,.r2
        ld a,c
        and 01Ch
        or d
        ld d,a
        ld a,c
        rrca
        rrca
        and c
        and 3                   ; column 27 over 25, 28 over 26
        or e
        ld e,a
        ld a,l
        add a,32+5              ; next row, column 29
        ld l,a
        jr nc,.r5
        inc h
.r5:    djnz .r
        ld a,d
        or a
        jr z,.n
        ld a,e
        or a
        ld a,2
        jr z,.n
        xor a
.n:     pop de
        pop bc
        ret
.no:    xor a
        ret

; =============================================================================
; Sprites: visible HUD first, then messages and arcade objects.
; =============================================================================
build_spat:
        ld a,(set_bank)
        add a,SET_DIRECT_BANKOFF
        ld (p1_cur),a
        ld (BANK_P1),a          ; page 1: the set's direct sprite table
        ld a,(spat_stg)
        xor 1
        ld (spat_stg),a         ; build into the other staging buffer
        ld hl,VR_STG_A&0FFFFh
        or a
        jr z,.base
        ld h,VR_STG_B>>8&0FFh
.base:  ld a,VR_STG_A>>16
        call v9_setw
        ld a,(hud_count)
        ld (spat_cnt),a
        or a
        jr z,.messages
        add a,a
        add a,a
        ld b,a
        ld c,V9_VRAM
        ld hl,spat_buf
        otir
.messages:
        call tsm_emit           ; message sprites take priority over all objects
        ld a,020h
        ld (ent_pr),a           ; the arcade's entries behind plane A
        ld a,(ARC_HELI)         ; the helicopter: its entries in front of plane A (palm trees) and
        ld (heli_on),a          ; of the structures drawn as sprites (emitted after the entries)
        or a
        jr nz,.heli
        call bgo_emit           ; the structures drawn as sprites, in front of the actors
        call spat_chain         ; entries 0-95 (generated: tools/gen_spat.py)
        jr .end
.heli:  call spat_chain
        ld a,020h
        ld (ent_pr),a
        call bgo_emit
.end:
        ; the entries this buffer used the last time beyond the count are disabled
        ld a,(spat_cnt)
        ld e,a
        ld (spat_used),a
        ld (spat_last),a
        ld hl,spat_n_a
        ld a,(spat_stg)
        or a
        jr z,.cnt
        inc l
.cnt:   ld a,(hl)
        ld (hl),e
        sub e
        jr c,.nodis
        jr z,.nodis
        ld b,a
.dis:   ld a,216
        out (V9_VRAM),a
        xor a
        out (V9_VRAM),a
        out (V9_VRAM),a
        ld a,010h
        out (V9_VRAM),a
        djnz .dis
.nodis: ld a,(spat_stg)
        ld (spat_show),a
        ld a,1
        ld (spat_ready),a
        ret

        include "../build/port/spat_chain.inc"

; B = arcade sprite entry while the helicopter is active: its rotor (entries 6-14) and body
; (19-40) in front of plane A. Keeps BC, DE, HL.
spat_fast_rom:
        phase spr_stamp
heli_entry:
        ld a,b
        sub 6
        cp 9
        jr c,.front
        ld a,b
        sub 19
        cp 22
        ld a,020h
        jr nc,.set
.front: xor a
.set:   ld (ent_pr),a
        ret

; One shown entry -> the SPAT stream. In (from spat_chain): L = code, H =
; attribute, E = Y byte (the V9990 X), D = X byte (the line), B = entry
; number. Page 1 = the set's direct table. Uses AF, BC, HL (DE kept).
spat_vis:
        ld a,(heli_on)
        or a
        call nz,heli_entry      ; ent_pr of this entry
        ld c,h                  ; C = attribute
        ld a,h
        rrca
        rrca
        and 03Fh
        add a,040h
        ld h,a                  ; direct table entry: bank | pal | flips, code
        ld a,(hl)               ; fixed slot, SPR_FIX + decoration, $FD not drawn, $FE/$FF dynamic
        cp SPR_FIX
        jp nc,spat_special
        ld b,a                  ; B = the fixed slot
        cp SPR_GUN0
        jr nc,.gun
.vis:   ld a,(spat_cnt)         ; the gunner can emit two entries, each bounded independently
        cp SPAT_LIMIT
        ret nc
        ld a,216
        sub d                   ; line = 216 - X + 256 * attr.b0 (arcade line 240 - X9 - CROP_TOP): visible when -15..211
        jr c,.neg
        bit 0,c
        ret nz
        cp 212
        ret nc
        jr .put
.neg:   bit 0,c
        jr z,.negs
        cp 212
        ret nc
        jr .put
.negs:  cp 0F1h
        ret c
.put:   dec a
        out (V9_VRAM),a         ; SPAT Y = line - 1
        ld a,b
        out (V9_VRAM),a         ; pattern slot
        ld a,e
        out (V9_VRAM),a         ; X
        ld a,c
        and 030h                ; palette 0: block 2, else block 3
        ld a,080h               ; block 2
        jr z,.blk
        ld a,0C0h               ; block 3
.blk:   ld hl,ent_pr
        or (hl)                 ; P = 1: behind plane A (not the helicopter)
        out (V9_VRAM),a
        ld hl,spat_cnt
        inc (hl)
        ret
; a bunker gunner: drawn GUN_DOWN lines lower (in front), with its bunker's plane A
; cells (8-line rows, 2 lines below the exact place), then at its place behind: its
; top rows (roof) fill the gap above, the lower copy covers the background's light
; roof edge under it
.gun:   ld a,d
        sub GUN_DOWN
        jr nc,.g1
        bit 0,c
        jr z,.g2                ; X9 < 0: below the screen
        res 0,c
.g1:    ld d,a
        call .vis
        ld a,d
        add a,GUN_DOWN
        ld d,a
        jr nc,.g2
        set 0,c
.g2:    jr .vis
        dephase
spat_fast_end:
        assert spat_fast_end-spat_fast_rom <= SPR_FIX
spat_special:
        cp 0FDh
        ret z                   ; not drawn (bank 3, empty sprite)
        jr nc,.dyn
        push af                 ; a moving door (deco_sprite) or a structure drawn as sprites
        push hl                 ; (bgo_spr): a real sprite
        push de
        sub SPR_FIX
        ld e,a
        ld d,0
        ld hl,deco_sprite
        add hl,de
        ld a,(hl)
        or a
        jr nz,.dsp
        ld a,(bgo_ebase)        ; the entry of structure slot 0 (x 4)
        rrca
        rrca
        and 03Fh
        ld e,a
        ld a,b                  ; this entry
        sub e
        cp 36
        jr nc,.dsp0
        rrca
        rrca
        and 0Fh                 ; its slot
        ld e,a
        ld hl,bgo_spr
        add hl,de
        ld a,(hl)
        rrca                    ; 1 -> $80: composed from the plane A patterns
        jr .dsp
.dsp0:  xor a
.dsp:   pop de
        pop hl
        or a
        jr z,.deco
        and 080h
        ld (bs_deco),a          ; (a door: the atlas sprite, 0)
        pop af
        sub SPR_FIX
        add a,a
        bit 3,c                 ; flip Y
        jr z,.nfy
        inc a
.nfy:   ld (bs_deco_id),a
        ld a,0FFh
        jr .dyn2
.deco:  pop af
        ; a decoration: no SPAT entry, plane A cells instead (alternate builds, entry parity)
        sub SPR_FIX
        push af
        ld a,e
        ld (bs_x),a             ; its x for the record
        ld a,b
        add a,a
        add a,a
        add a,2
        ld l,a
        ld h,SPRITERAM>>8
        jr nc,.pg
        inc h
.pg:    ld a,(ovl_sweep_ctr)    ; HL = the entry's Y byte
        rlca
        rlca
        xor l
        and 4
        jr nz,.deco_skip
        pop af
        call overlay_entry      ; A = decoration, HL = Y byte, C = attribute (keeps BC, DE, HL)
        jp .resume              ; (its cell writes move the VRAM address)
.deco_skip:
        pop af
        ret
.dyn:   ld (bs_front),a         ; $FE: in front of plane A
        xor a
        ld (bs_deco),a
        jr .dyn3
.dyn2:  ld (bs_front),a
.dyn3:  ld a,(spat_cnt)
        cp SPAT_LIMIT
        ret nc
        ld a,216                ; visible? (before the cache lookup: an entry parked off
        sub d                   ; the screen costs nothing then)
        jr c,.dneg
        bit 0,c
        ret nz
        cp 212
        ret nc
        jr .dlook
.dneg:  bit 0,c
        jr z,.dnegs
        cp 212
        ret nc
        jr .dlook
.dnegs: cp 0F1h
        ret c
.dlook: push af                 ; the line
        push bc
        push de
        ld a,c                  ; key: L = code, H = bank | flip<<2 | pal<<4
        rlca
        rlca
        and 3
        ld h,a
        ld a,c
        and 03Ch
        or h
        ld h,a
        ld a,(bs_deco)          ; bit 7: the plane A decoration version (block 1)
        or h
        ld h,a
        call spr_get_dyn        ; A = slot, C = block << 6
        ld (bs_slot),a
        ld a,(bs_front)
        inc a                   ; $FF -> 0: behind plane A (unless the helicopter)
        ld a,c
        jr nz,.front
        ld hl,ent_pr
        or (hl)
.front: ld (bs_blk),a
        pop de
        pop bc
        ld a,(vram_moved)       ; a cache fill (CPU upload) moved the VRAM address
        or a
        call nz,spat_resume
        pop af
        dec a
        out (V9_VRAM),a
        ld a,(bs_slot)
        out (V9_VRAM),a
        ld a,e
        out (V9_VRAM),a
        ld a,(bs_blk)
        out (V9_VRAM),a
        ld hl,spat_cnt
        inc (hl)
        ret
.resume:
        ld a,(vram_moved)
        or a
        call nz,spat_resume
        ret

; VRAM write address := the next SPAT entry of the staging buffer (spat_cnt entries written). Keeps all but AF.
spat_resume:
        xor a
        ld (vram_moved),a
        push hl
        push de
        ld a,(spat_cnt)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl               ; 4 * E
        ld a,(spat_stg)
        or a
        ld a,VR_STG_A>>8&0FFh
        jr z,.ba
        ld a,VR_STG_B>>8&0FFh
.ba:    add a,h
        ld h,a
        ld a,VR_STG_A>>16
        call v9_setw
        pop de
        pop hl
        ret

; In the vertical retrace: the finished staging image -> SPAT (an LMMM of
; its 512 bytes: 4 lines of 128 bytes). The VRAM port is not used, so a
; build in progress (interrupted) keeps its stream.
spat_copy:
        ld a,(spat_ready)
        or a
        ret z
        in a,(V9_STAT)
        bit 6,a
        ret z                   ; not in the retrace: next time
        rrca
        ret c                   ; a command still runs (HUD compose): next time
        xor a
        ld (spat_ready),a
        ld a,(hud_count)
        ld (hud_presented),a
        ld a,32
        out (V9_REGS),a         ; R#32.. with auto-increment
        xor a
        out (V9_REGD),a         ; SX
        out (V9_REGD),a
        ld a,(spat_show)
        or a
        ld hl,VR_STG_A/128      ; SY = line of the staging buffer
        jr z,.sy
        ld hl,VR_STG_B/128
.sy:    ld a,l
        out (V9_REGD),a         ; R#34 SY
        ld a,h
        out (V9_REGD),a
        xor a
        out (V9_REGD),a         ; R#36 DX
        out (V9_REGD),a
        ld hl,VR_SPAT/128
        ld a,l
        out (V9_REGD),a         ; R#38 DY
        ld a,h
        out (V9_REGD),a
        xor a
        out (V9_REGD),a         ; R#40 NX = 256
        ld a,1
        out (V9_REGD),a
        ld a,4
        out (V9_REGD),a         ; R#42 NY = 4
        xor a
        out (V9_REGD),a
        out (V9_REGD),a         ; R#44 ARG
        ld a,00Ch
        out (V9_REGD),a         ; R#45 LOP: D = S
        ld a,0FFh
        out (V9_REGD),a         ; R#46 WM
        xor a                   ; R#47: protect plane B for this plane A destination
        out (V9_REGD),a         ; R#47
        ld a,52
        out (V9_REGS),a
        ld a,040h
        out (V9_REGD),a         ; R#52: LMMM
        ret

bs_x    equ OVL_VARS+10
spr_idx equ SET_SIDX_OFF+04000h ; atlas index of each sprite (in every set's index bank)

; slot C := the 4 plane A patterns of decoration bs_deco_id (TL, TR, BL, BR),
; already in the set's colours: a structure drawn as sprites (bgo_spr) uses
; palette block 1 like plane A. Returns A = block 1 << 6.
spr_fill_deco:
        push bc
        ld a,(bs_deco_id)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,OVL_BASE
        ld a,(deco_tmp)
        or a
        jr z,.pa
        ld de,(VR_DECOTMP-VR_PATB)/1024*32 ; the next set's, converted aside: its lines as
        ld a,2                  ; pattern rows, X + 512 (the plane B half)
.pa:    ld (lp_sxh),a
        add hl,de
        ex de,hl                ; DE = TL pattern
        ld hl,0000h
        call lmmm_pat
        inc de
        ld hl,0800h
        call lmmm_pat
        inc de
        ld hl,0008h
        call lmmm_pat
        inc de
        ld hl,0808h
        call lmmm_pat
        xor a
        ld (lp_sxh),a
        pop bc
        ld a,040h
        ret

; =============================================================================
; Decorations on plane A (palm trees, rocks, bridges, gorge walls, river
; banks): the arcade draws them as sprites; the port writes their 2x2 cells
; on plane A instead, which scrolls with the map, so the actors (sprites with
; P = 1) pass behind them. The direct sprite table marks them (SPR_FIX + k).
; Per sprite entry a record (entry - $200): x, map y M = y9 + P (lo, hi | $80 =
; seen this frame) and id. The cells are written only when the record
; changes; the sweep after the build clears the records not seen.
; Rows: the sprite would start at line 216 - y9 = 240 - M + SCAY, so the cell
; rows are (244 - M) / 8 (rounded) and + 1; X = (x + 4) / 8.
; =============================================================================
; A = decoration k, HL = Y byte of the entry, C = attribute. Keeps BC, DE, HL.
overlay_entry:
        push hl
        push de
        push bc
        add a,a
        bit 3,c                 ; flip Y
        jr z,.nf
        inc a
.nf:    ld b,a                  ; B = id = 2k + flip Y (patterns OVL_BASE + 4 * id; 0-147, a
                                ; whole byte: the seen flag is bit 7 of the M hi byte)
        inc l
        ld e,(hl)               ; X byte
        ld a,c
        and 1
        ld d,a                  ; DE = y9
        ld a,(arc_scroll_lo)
        add a,e
        ld e,a
        ld a,(arc_scroll_hi)
        adc a,d
        and 1
        ld d,a                  ; DE = M mod 512
        ld a,h
        sub 2
        ld h,a                  ; HL = record + 3 (id byte)
        ld a,(hl)
        cp b
        jr nz,.ch3
        dec l
        ld a,(hl)
        and 07Fh
        cp d
        jr nz,.ch2
        dec l
        ld a,e
        cp (hl)
        jr nz,.ch1
        dec l
        ld a,(bs_x)
        cp (hl)
        jr nz,.ch0
        inc l
        inc l
        set 7,(hl)              ; same decoration at the same place: seen (M hi bit 7)
        pop bc
        pop de
        pop hl
        ret
.ch3:   dec l
.ch2:   dec l
.ch1:   dec l
.ch0:   ld (ov_rec),hl          ; record + 0
        ld a,(hl)
        or a
        jr z,.new
        push de
        push bc
        call ovl_rec_unput      ; the old cells (the record still describes them)
        pop bc
        pop de
        jr .fill
.new:   ld a,(ovl_count)        ; a record with cells: its entry number into the sweep list
        add a,ovl_list&255
        ld l,a
        ld h,ovl_list>>8
        ld a,(ov_rec)
        rrca
        rrca
        and 03Fh
        ld (hl),a
        ld a,(ov_rec+1)         ; bit 6 of the number = page $FD
        and 1
        rrca
        rrca
        or (hl)
        ld (hl),a
        ld hl,ovl_count
        inc (hl)
.fill:  ld hl,(ov_rec)
        ld a,(bs_x)
        ld (hl),a
        inc l
        ld (hl),e
        inc l
        ld a,d
        or 080h
        ld (hl),a               ; M hi | seen
        inc l
        ld (hl),b               ; id
        ld a,b
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,OVL_BASE
        add hl,de
        ex de,hl                ; DE = first pattern
        ld bc,1                 ; consecutive patterns
        call overlay_put
        pop bc
        pop de
        pop hl
        ret

; clear the cells of the record (ov_rec)
overlay_clear:
        ld de,PATA_BLANK
        ld bc,0                 ; the same word 4 times
; write the 2x2 cells of the record (ov_rec): patterns DE, DE+BC, DE+2BC,
; DE+3BC (TL, TR, BL, BR). Interrupts off around the ports. Uses AF, DE, HL.
overlay_put:
        ld a,(deco_block)
        or a
        ret nz                  ; after bg_clear, until map_set_position
        ld a,1
        ld (vram_moved),a
        ld hl,(ov_rec)
        ld a,(hl)
        add a,4
        rra
        rra
        rra
        and 31
        ld (ov_x),a             ; X (the carry of the addition is the wrap: x < 256)
        cp 1
        ret c                   ; columns 0-1 and 30-31 are the black margins (the arcade clips there):
        cp 30                   ; X = 1 or 29 writes only the half on the screen
        ret nc
        inc l
        ld a,(hl)
        inc l
        ld h,(hl)
        ld l,a
        res 7,h                 ; HL = M (bit 7 of a sprite-entry record's M hi = seen)
        ex de,hl                ; DE = M, HL = pattern
        push hl
        ld hl,244
        or a
        sbc hl,de
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; << 5: bits 8-13 = (244 - M) >> 3
        ld a,h
        and 63
        ld d,a                  ; row
        ld a,(ov_x)
        ld e,a                  ; X
        pop hl                  ; pattern
        ld a,i
        push af
        di
        call .row               ; TL, TR
        inc d
        call .row               ; BL, BR
        pop af
        ret po
        ei
        ret
; the 2 cells of row D from X = E: patterns HL, HL+BC (HL advances by 2 BC); X = 1: the
; left cell is in the black margin (column 1), X = 29: the right one (column 30)
.row:   push de
        ld a,e
        cp 1
        jr nz,.left
        inc e
        add hl,bc
        push hl
        call pnta_addr
        call v9_setw
        pop hl
        jr .right
.left:  push hl
        call pnta_addr
        call v9_setw
        pop hl
        ld a,l
        out (V9_VRAM),a
        ld a,h
        out (V9_VRAM),a
        add hl,bc
        ld a,e
        cp 29
        jr z,.skip
.right: ld a,l
        out (V9_VRAM),a
        ld a,h
        out (V9_VRAM),a
.skip:  add hl,bc
        pop de
        ret

; clear the 2x2 cells of the record (ov_rec) that still hold the patterns DE,
; DE+BC, DE+2BC, DE+3BC (TL, TR, BL, BR): a cell another decoration or a text
; has been written over keeps it. Interrupts off around the ports.
overlay_unput:
        ld a,(deco_block)       ; (ov_umode: an under-write, held back like overlay_put)
        ld hl,ov_umode
        and (hl)
        ret nz
        ld a,1
        ld (vram_moved),a
        ld hl,(ov_rec)
        ld a,(hl)
        add a,4
        rra
        rra
        rra
        and 31
        ld (ov_x),a
        cp 1                    ; X = 1: its left cells are the margin's (black: kept)
        ret c
        cp 30
        ret nc
        inc l
        ld a,(hl)
        inc l
        ld h,(hl)
        ld l,a
        res 7,h                 ; HL = M (bit 7 of a sprite-entry record's M hi = seen)
        ex de,hl                ; DE = M, HL = pattern
        push hl
        ld hl,244
        or a
        sbc hl,de
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,h
        and 63
        ld d,a                  ; row
        ld a,(ov_x)
        ld e,a                  ; X
        pop hl                  ; pattern
        ld a,i
        push af
        di
        call .cell
        add hl,bc
        inc e
        call .cell
        add hl,bc
        dec e
        inc d
        call .cell
        add hl,bc
        inc e
        call .cell
        pop af
        ret po
        ei
        ret
.cell:  push hl
        push bc
        ld b,h
        ld c,l                  ; BC = the pattern this record wrote there
        call pnta_addr          ; A:HL = the cell (A = 7)
        call v9_setr
        ld a,(ov_umode)
        or a
        jr nz,.under
        in a,(V9_VRAM)
        cp c
        jr nz,.keep
        in a,(V9_VRAM)
        cp b
        jr nz,.keep
        ld a,VR_PNTA>>16
        call v9_setw
        ld bc,PATA_BLANK
        ld a,e
        cp 30
        jr c,.wr
        ld bc,PATA_BLACK        ; the right margin (a quad at X = 29) stays black
.wr:    ld a,c
        out (V9_VRAM),a
        ld a,b
        out (V9_VRAM),a
.keep:  pop bc
        pop hl
        ret
.under: ld a,e                  ; (ov_umode) the pattern BC written if the cell is blank
        cp 30
        jr nc,.keep             ; the right margin (a quad at X = 29)
        in a,(V9_VRAM)
        cp PATA_BLANK&255
        jr nz,.keep
        in a,(V9_VRAM)
        cp PATA_BLANK>>8
        jr nz,.keep
        ld a,VR_PNTA>>16
        call v9_setw
        jr .wr

; A = plane A row: its decoration cells (patterns OVL_BASE..OVL_END-1) become
; blank, the margin cells (columns 0-1, 30-31) opaque black; the text cells
; stay. Call with interrupts off.
; Uses AF, BC, DE, HL.
deco_wipe_row:
        ld d,a
        ld e,0
        call pnta_addr          ; A:HL = the row (A = 7)
        call v9_setr
        call v9_setw            ; separate read and write pointers, both auto-incremented
        ld bc,32*256+V9_VRAM
.c:     in e,(c)
        in d,(c)
        ld a,b                  ; B = 32 - column: columns 0-1 and 30-31 are the black margin,
        cp 31                   ; always (a cell lost there is repaired)
        jr nc,.mg
        cp 3
        jr c,.mg
        ld hl,-OVL_BASE
        add hl,de
        jr nc,.keep             ; below OVL_BASE: font, blank, black
        ld hl,-OVL_END
        add hl,de
        jr c,.keep
        ld de,PATA_BLANK
        jr .keep
.mg:    ld de,PATA_BLACK
.keep:  out (c),e
        out (c),d
        djnz .c
        ret

; A = row, the same with the interrupt state kept (off around the row only)
deco_wipe_row_di:
        ld c,a
        ld a,1
        ld (vram_moved),a       ; the build's SPAT stream resumes its address
        ld a,i
        push af
        di
        ld a,c
        call deco_wipe_row
        pop af
        ret po
        ei
        ret

; A jump of the map position: every decoration cell blanked, the sprite-entry
; and static-list records emptied (drawn again by the next build / tick), the
; map structures (palm trees, rocks) drawn again at once from their records:
; while the helicopter hovers the arcade does not update them (it only sways
; them, and the sway rewrites drawn records only: the trees were missing)
deco_wipe_jump:
        call deco_wipe_cells
        call deco_reset_others
        jp bgo_redraw

; bg_clear: every plane A decoration cell blanked and every decoration record
; emptied (they are drawn again by their next update)
deco_wipe_all:
        call deco_wipe_cells
        call deco_reset_others
        ld hl,bgo_rec           ; map structure records
        ld b,9
        ld de,8
        xor a
.b:     ld (hl),a
        add hl,de
        djnz .b
        ret

deco_wipe_cells:
        xor a
.r:     push af
        call deco_wipe_row_di
        pop af
        inc a
        cp 64
        jr c,.r
        ret

deco_reset_others:
        ld hl,ovl_cache         ; sprite-entry records: x = 0
        ld b,96
.o:     ld (hl),0
        inc hl
        inc hl
        inc hl
        inc hl
        djnz .o
        xor a
        ld (ovl_count),a
        ld hl,dsl_rec           ; static list records
        ld b,24
        ld de,8
.d:     ld (hl),a
        add hl,de
        djnz .d
        ret

; After the build: the plane A row that has just left the screen at the bottom
; (screen y 240+, the name table wraps every 512 px) loses its decoration cells,
; so a cell left by a missed clear never comes back at the top; a jump of the
; map position (life start, next area) wipes them all.
deco_scroll_wipe:
        ld a,(arc_scroll_hi)
        ld h,a
        ld a,(arc_scroll_lo)
        ld l,a
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l                    ; HL = P / 8
        ld de,(wipe_last)
        ld (wipe_last),hl
        or a
        sbc hl,de
        ret z
        ld a,h
        or a
        jp nz,deco_wipe_jump    ; backwards or far: a jump
        ld a,l
        cp 5
        jp nc,deco_wipe_jump
        ld b,a
.s:     inc de
        ld a,33                 ; row 33 - P/8: screen y 240-247 + P mod 8
        sub e
        and 63
        push bc
        push de
        call deco_wipe_row_di
        pop de
        pop bc
        djnz .s
        ret

; rewrite the cells of every record with cells (after a text erase, which
; may have blanked some of them). Uses AF, BC, DE, HL.
ovl_redraw:
        ld a,(ovl_count)
        or a
        ret z
        ld b,a
        ld hl,ovl_list
.r:     ld a,(hl)
        inc hl
        push hl
        push bc
        call ovl_rec_of
        ld (ov_rec),hl
        ex de,hl
        inc e
        inc e
        inc e
        ld a,(de)               ; id
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,OVL_BASE
        add hl,de
        ex de,hl
        ld bc,1
        call overlay_put
        pop bc
        pop hl
        djnz .r
        ret

; =============================================================================
; Map structures (palm trees, rocks: bgobj_slots) on plane A. Replaces the
; arcade's bgobj_update_all (one hook call per tick instead of one per
; structure). Per slot: a free slot is skipped; an active one scrolls with the
; map (y - 1 when the screen moved), is freed below the screen, else it is
; marked seen in its record (x, M lo, M hi, code, attribute, seen, type; M =
; y + P). The record is compared with the slot and the cells (4 quads of a
; tree, 2 of a rock) rewritten only when it is stale: the slot was taken by
; a new structure (hook_spawn marks the record: seen = 2), it has no cells
; yet, or bgo_dirty is set (the sway state changed at the build). The sprite
; entries stay hidden: the arcade's budget (18 pairs for 9 slots) can never
; run out. A falling tree (debris countdown) draws its 4 debris sprites in
; the slot's own entries (base + 4n, base = entry 12, or 43 from substate 5;
; the build scans them). The hit list of the active
; slots (bgo_hits, bgo_hitlist: y, x, margin, width of the first 8 slots, as
; the arcade tests) is rebuilt for the hit tests of the tick (the update runs
; before the player, enemy and projectile updates). bgo_sweep clears the
; records of the slots not seen.
; =============================================================================
ovl_bgobj_all:
        call deco_scroll_wipe   ; the map has just moved (scroll_update returns through here): the
        ld hl,bgo_calls         ; row leaving at the bottom is wiped before the structures and the
        inc (hl)                ; static lists of this tick draw (after them, it cleared their new
                                ; cells 265-272 px above the screen: the gorge walls came without
                                ; their plane A half until some redraw)
        ld hl,SPRITERAM+030h
        ld a,(arc_game_state+1)
        cp 5
        jr c,.base
        ld hl,SPRITERAM+0ACh
.base:  ld (bgo_ebase),hl
        inc l
        inc l                   ; the 36 entries hidden, as bgobj_hide_rest does every tick (the map
        ld de,4                 ; objects drawn later in the tick share them: entries 1-53)
        ld b,36
.hide:  ld (hl),0
        add hl,de
        djnz .hide
        ld a,(arc_scroll_delta)
        ld b,a                  ; B = the map moved this tick
        ld de,bgo_hitlist       ; DE = hit list write pointer
        include "../build/port/bgobj_slots.inc"
        ld a,e
        sub bgo_hitlist&255
        rrca
        rrca
        ld (bgo_hits),a         ; entries of the hit list
        xor a
        ld (bgo_dirty),a
        jp bgo_overlap

; Overlapping map structures: a plane A cell holds one pattern, so where two
; trees overlap the later one's quads replaced the other's leaves and its
; transparent pixels showed the ground. A slot overlapping an earlier active
; slot (|dx| < 32 and |dy| < 32) is drawn as sprites instead (bgo_emit, in
; the SPAT build); plane A (the other tree) stays in front of it and the
; actors behind both. Entering the mode clears the slot's cells; leaving it
; lets the next update draw them.
bgo_overlap:
        ld ix,0E800h            ; slot n
        ld c,0                  ; n
.n:     ld e,0                  ; E = overlaps an earlier slot
        ld a,(ix+0)
        inc a
        jr nz,.flag             ; not an active structure
        ld a,c
        or a
        jr z,.flag
        ld b,c
        ld hl,0E800h            ; slot m < n
.m:     ld a,(hl)
        inc a
        jr nz,.mn
        push hl
        inc l
        inc l
        inc l
        ld a,(hl)               ; x of m
        sub (ix+3)
        add a,31
        cp 63
        jr nc,.far
        inc l
        ld d,(hl)               ; y hi of m
        inc l
        ld a,(hl)               ; y lo of m
        sub (ix+5)
        ld l,a
        ld a,d
        sbc a,(ix+4)
        ld h,a                  ; HL = y(m) - y(n)
        ld a,l
        add a,31
        ld l,a
        ld a,h
        adc a,0
        or a
        jr nz,.far
        ld a,l
        cp 63
        jr nc,.far
        inc e                   ; overlap
.far:   pop hl
        ld a,e
        or a
        jr nz,.flag
.mn:    ld a,l
        add a,16
        ld l,a
        djnz .m
.flag:  ld b,0
        ld hl,bgo_spr
        add hl,bc
        ld a,(hl)
        cp e
        jr z,.same
        ld (hl),e
        ld a,e
        or a
        jr z,.same              ; leaving: the record is empty, the next update draws the cells
        push bc
        ld a,c                  ; entering: the slot's cells cleared
        add a,a
        add a,a
        add a,a
        add a,bgo_rec&255
        ld l,a
        ld h,bgo_rec>>8
        ld a,(hl)
        or a
        jr z,.nocells
        ld a,1
        ld (bgo_mode),a
        call bgo_quads          ; (IX = the slot)
        ld hl,(bgo_cur)
        ld (hl),0
.nocells:
        pop bc
.same:  ld de,16
        add ix,de
        inc c
        ld a,c
        cp 9
        jp c,.n
        ret

; Before the 96 arcade entries (so in front of the actors): the structures drawn
; as sprites (bgo_spr), through spat_vis with the entry numbers of their slot
; (base + 4n + i, which spat_vis maps back to the slot) and the values
; bgobj_draw would write: tree C / C+1 at y, C-8 / C-7 at y + 16 (columns
; swapped when mirrored), rock C / C+1. Not in the arcade's entries: while the
; helicopter hovers it uses them, and the structure update does not run.
bgo_emit:
        ld a,(deco_block)
        or a
        ret nz
        ld a,(bgo_ebase)
        rrca
        rrca
        and 03Fh
        ld (bgo_e0),a
        ld ix,0E800h
        xor a
.n:     ld (bgo_en),a
        ld e,a
        ld d,0
        ld hl,bgo_spr
        add hl,de
        ld a,(hl)
        or a
        jp z,.next
        ld a,(ix+0)
        inc a
        jp nz,.next
        call bgo_code           ; the sway frame's code while the helicopter hovers
        ld (bgo_ec),a
        ld a,(ix+3)
        ld d,a
        add a,16
        ld e,a
        bit 3,(ix+8)            ; mirrored: the columns swap
        jr z,.nm
        ld a,d
        ld d,e
        ld e,a
.nm:    ld a,d
        ld (bgo_exa),a
        ld a,e
        ld (bgo_exb),a
        ld l,(ix+5)
        ld h,(ix+4)
        ld c,0                  ; bottom row: entries 0-1
        ld a,(bgo_ec)
        call .row
        ld a,(ix+6)
        or a
        jr nz,.next             ; a rock: one row
        ld l,(ix+5)
        ld h,(ix+4)
        ld de,16
        add hl,de
        ld c,2                  ; top row: entries 2-3
        ld a,(bgo_ec)
        sub 8
        call .row
.next:  ld de,16
        add ix,de
        ld a,(bgo_en)
        inc a
        cp 9
        jp c,.n
        ret
; HL = y, A = left code, C = first entry index in the slot (0 / 2)
.row:   push af
        ld a,h
        and 1
        add a,(ix+8)
        ld (bs_x),a             ; (scratch) attribute + y bit 8
        pop af
        push af
        ld b,a
        ld a,(bgo_exa)
        call .one
        pop af
        inc a
        inc c
        ld b,a
        ld a,(bgo_exb)
; B = code, A = x (screen), L = y low, C = entry index: one sprite through spat_vis
.one:   or a
        ret z                   ; x 0: hidden, as the arcade's scan skips it
        push hl
        push bc
        push ix
        ld e,a
        ld d,l
        ld l,b
        ld a,(bs_x)
        ld h,a
        ld a,(bgo_en)
        add a,a
        add a,a
        add a,c
        ld b,a
        ld a,(bgo_e0)
        add a,b
        ld b,a                  ; entry = e0 + 4n + index
        call spat_vis
        pop ix
        pop bc
        pop hl
        ret

; The record HL of the active slot IX may be stale: compare it with the slot
; (x, M = y + P, effective code, attribute) and rewrite the cells on change.
; Keeps DE.
bgo_full:
        push de
        ld a,(arc_scroll_lo)
        add a,(ix+5)
        ld e,a
        ld a,(arc_scroll_hi)
        adc a,(ix+4)
        and 1
        ld d,a                  ; DE = M = y + P
        call bgo_code           ; the sway frame's code while the helicopter hovers
        ld c,a                  ; C = effective code
        ld a,(ix+3)
        cp (hl)
        jr nz,.ch0
        inc l
        ld a,e
        cp (hl)
        jr nz,.ch1
        inc l
        ld a,d
        cp (hl)
        jr nz,.ch2
        inc l
        ld a,c
        cp (hl)
        jr nz,.ch3
        inc l
        ld a,(ix+8)
        cp (hl)
        jr nz,.ch4
        inc l
        ld (hl),1               ; seen
        pop de
        ret
.ch4:   dec l
.ch3:   dec l
.ch2:   dec l
.ch1:   dec l
.ch0:   ld a,(hl)
        or a
        jr z,.write
        push hl
        push de
        push bc
        ld a,1
        ld (bgo_mode),a
        call bgo_quads          ; the old cells
        pop bc
        pop de
        pop hl
.write: ld a,(ix+3)
        ld (hl),a
        inc l
        ld (hl),e
        inc l
        ld (hl),d
        inc l
        ld (hl),c
        inc l
        ld a,(ix+8)
        ld (hl),a
        inc l
        ld (hl),1
        inc l
        ld a,(ix+6)
        ld (hl),a
        ld a,l
        and 0F8h
        ld l,a
        xor a
        ld (bgo_mode),a
        call bgo_quads
        pop de
        ret

; A falling tree: slot IX (+0 = $3F.. just destroyed, $10..1 countdown), A =
; its offset (16 n): the 4 debris sprites go to the slot's own entries
; (bgo_ebase + 4 n), hidden when the countdown ends. Keeps DE.
bgo_debris:
        push de
        ld iy,(bgo_ebase)
        ld e,a
        ld d,0
        add iy,de
        ld a,(ix+0)
        cp 03Fh
        jr nc,.destroyed        ; $3F..: just destroyed (blast)
        dec (ix+0)              ; countdown $10 -> 0, then the slot is free
        jr z,.free
        ld de,tab_debris_a      ; frames $0F-$08: code $14, frames $07-$01: code $15
        ld c,014h
        ld a,(ix+0)
        cp 8
        jr nc,.frame
        ld de,tab_debris_b
        ld c,015h
.frame: ld (iy+0),c            ; codes C, C (mirrored), C+7, C+7 (mirrored)
        ld (iy+4),c
        ld a,c
        add a,7
        ld (iy+8),a
        ld (iy+12),a
        ld (iy+1),0B0h
        ld (iy+5),0B8h
        ld (iy+9),0B0h
        ld (iy+13),0B8h
        ld a,(arc_scroll_delta)
        or a
        jr z,.dpos
        dec (ix+5)              ; the debris scrolls too (low byte only, as the arcade)
.dpos:  ld a,(de)               ; sprites 0/2: x + ofs[0]; sprites 0/1: y + ofs[1]
        inc de
        add a,(ix+3)
        ld (iy+2),a
        ld (iy+10),a
        ld a,(de)
        inc de
        add a,(ix+5)
        ld (iy+3),a
        ld (iy+7),a
        ld a,(de)               ; sprites 1/3: x + ofs[2]; sprites 2/3: y + ofs[3]
        inc de
        add a,(ix+3)
        ld (iy+6),a
        ld (iy+14),a
        ld a,(de)
        add a,(ix+5)
        ld (iy+11),a
        ld (iy+15),a
        pop de
        ret
.destroyed:
        ld (ix+0),010h          ; 16 frames of debris
        push hl
        ld d,5                  ; command 5 (score), parameter 2: the points of a palm tree
        ld e,2
        rst 038h                ; queue_cmd (page 0 RAM)
        pop hl
        pop de
        ret
.free:  ld (ix+0),0
        ld (iy+2),0             ; its debris entries hidden
        ld (iy+6),0
        ld (iy+10),0
        ld (iy+14),0
        pop de
        ret

; debris offsets (x0, y0, x1, y1): first 8 frames, last 8 frames (tab_debris_ofs_a/b)
tab_debris_a:
        db 0F9h,013h,017h,0FEh
tab_debris_b:
        db 0F2h,014h,01Eh,0FBh

; A = the slot's (IX) sprite code: the sway frame's for a palm tree while the helicopter
; hovers (a rock keeps its own: with the tree's code it showed as half a tree over the
; rock during the lap-end flight)
bgo_code:
        ld a,(sway_on)
        or a
        jr z,.slot
        ld a,(ix+6)
        or a
        jr nz,.slot
        ld a,(sway_eff)
        ret
.slot:  ld a,(ix+7)
        ret

; heli_sway_trees (the palm trees sway under the hovering helicopter): the
; arcade writes the frame's codes into the (hidden) sprite entries of every
; structure; here the tree records get the frame's bottom-left code and
; their cells are rewritten in place (the quads keep their positions, so
; nothing is cleared), at most 3 trees per call: a full rewrite of 9 trees
; cost ~23 ms in one tick, the sway frame lasts several ticks and a tree
; one or two ticks behind is invisible. sway_code = the top-left code.
ovl_sway:
        ld a,(sway_code)
        add a,8
        ld (sway_eff),a
        ld a,1
        ld (sway_hit),a
        ld hl,bgo_rec
        ld bc,9*256+3           ; B = records, C = rewrites left this call
.s:     push bc
        push hl
        ld a,(hl)
        or a
        jr z,.n                 ; no cells
        ld a,l
        add a,6
        ld l,a
        ld a,(hl)
        or a
        jr nz,.n                ; a rock
        ld a,l
        sub 3
        ld l,a                  ; code byte
        ld a,(sway_eff)
        cp (hl)
        jr z,.n
        ld (hl),a
        ld a,l
        and 0F8h
        ld l,a
        xor a
        ld (bgo_mode),a
        call bgo_quads
        pop hl
        pop bc
        dec c
        ret z
        jr .nn
.n:     pop hl
        pop bc
.nn:    ld a,l
        add a,8
        ld l,a
        djnz .s
        ret

; the quads of the record HL: (bgo_mode) 0 = write the cells, 1 = clear them
bgo_quads:
        ld (bgo_cur),hl
        ld a,(hl)
        ld (bgo_xa),a           ; x of the code C / C-8 column
        add a,16
        ld (bgo_xb),a           ; x of the code C+1 / C-7 column
        ld a,l
        add a,4
        ld l,a
        ld a,(hl)               ; attribute
        and 008h
        rrca
        rrca
        rrca
        ld (bgo_flip),a
        jr z,.nm
        ld a,(bgo_xa)           ; mirrored: the columns swap
        ld c,a
        ld a,(bgo_xb)
        ld (bgo_xa),a
        ld a,c
        ld (bgo_xb),a
.nm:    ld a,(bgo_xa)
        ld (bgo_x),a
        call .load              ; DE = M, A = code
        call bgo_one
        ld a,(bgo_xb)
        ld (bgo_x),a
        call .load
        inc a                   ; C+1
        call bgo_one
        ld hl,(bgo_cur)
        ld a,l
        add a,6
        ld l,a
        ld a,(hl)               ; type: a rock has one row
        or a
        ret nz
        ld a,(bgo_xa)
        ld (bgo_x),a
        call .load16            ; the top row: M + 16
        sub 8                   ; C-8
        call bgo_one
        ld a,(bgo_xb)
        ld (bgo_x),a
        call .load16
        sub 7                   ; C-7
        jp bgo_one
.load16:
        call .load
        push af
        ld hl,16
        add hl,de
        ld a,h
        and 1
        ld d,a
        ld e,l
        pop af
        ret
.load:  ld hl,(bgo_cur)
        inc l
        ld e,(hl)
        inc l
        ld d,(hl)
        inc l
        ld a,(hl)
        ret

; one quad: A = sprite code (bank 2 palette 3), (bgo_x) = x, DE = M
bgo_one:
        ld hl,bgo_tmp
        ld (ov_rec),hl
        ld c,a
        ld a,(bgo_x)
        ld (hl),a
        inc l
        ld (hl),e
        inc l
        ld (hl),d
        ld a,(bgo_mode)
        or a
        jp nz,overlay_clear
        ld h,ovl_k2p3>>8
        ld l,c
        ld a,(hl)
        cp 0FFh
        ret z                   ; not a decoration (never for the known codes)
        add a,a
        ld hl,bgo_flip
        add a,(hl)              ; id = 2k + flip Y
; A = decoration id, (ov_rec) -> bgo_tmp with x and M: write the quad
deco_put_id:
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,OVL_BASE
        add hl,de
        ex de,hl
        ld bc,1
        jp overlay_put
; the same quad cleared where its cells still hold its patterns
deco_unput_id:
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,OVL_BASE
        add hl,de
        ex de,hl
        ld bc,1
        jp overlay_unput
; the same quad written only into the blank cells: a moving door's static list
; (door closed) goes under its frame's cells. The arcade draws the dugout's
; lintel (and the fortress gate's pillars) first: earlier entries are in front;
; the door's top cells replaced the lintel's lower half, and the opening door
; (sprites, behind plane A) showed over the roof.
deco_under_id:
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,OVL_BASE
        add hl,de
        ex de,hl
        ld bc,1
        ld a,1
        ld (ov_umode),a
        call overlay_unput
        xor a
        ld (ov_umode),a
        ret
; the cells of the sprite-entry record (ov_rec) cleared where they still hold its patterns
ovl_rec_unput:
        ld hl,(ov_rec)
        inc l
        inc l
        inc l
        ld a,(hl)               ; id
        jr deco_unput_id

; =============================================================================
; Static map structures (bunkers, bridges, gorge walls, river banks) on
; plane A: hook of draw_sprite_list for the object types of dsl_static
; (resident). IX = object, IY = first sprite entry, DE = list: N, attribute,
; N x (offset, code); offset high nibble = x offset (x 16, 8-bit wrap), low
; nibble = y offset (signed, x 16). Per (object slot, n-th list drawn by it
; this tick) a record: x, M lo, M hi (M = y + P), list address, seen, 0.
; The cells are written on change; dsl_sweep clears the records not drawn.
; The sprite entries get Y = 0 and the attribute (+ y bit 8) as the arcade
; writes it (the bunker gunner reads it); IY and DE advance as in the arcade.
; =============================================================================
ovl_dsl:
        ld a,1
        ld (dsl_any),a
        ld a,(set_bank)
        add a,SET_DIRECT_BANKOFF
        ld (p1_cur),a
        ld (BANK_P1),a          ; page 1: the direct sprite table (code -> decoration)
        push ix
        pop hl
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
        ld a,(hl)               ; n-th list of this slot this tick (counted by hook_dsl)
        dec a
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
        ld h,0
        ld bc,dsl_rec
        add hl,bc
        ld (dsl_cur),hl         ; the record
        ld a,(arc_scroll_lo)
        add a,(ix+5)
        ld c,a
        ld a,(arc_scroll_hi)
        adc a,(ix+4)
        and 1
        ld b,a                  ; BC = M = y + P
        ld a,(ix+3)
        cp (hl)
        jr nz,.changed
        inc l
        ld a,c
        cp (hl)
        jr nz,.changed
        inc l
        ld a,b
        cp (hl)
        jr nz,.changed
        inc l
        ld a,e
        cp (hl)
        jr nz,.changed
        inc l
        ld a,d
        cp (hl)
        jr nz,.changed
        inc l
        ld (hl),1               ; seen: the entries stay hidden; IY and DE advance as in the arcade
        ld a,(de)               ; N
        ld l,a
        ld h,0
        add hl,hl               ; 2 N
        push hl
        add hl,hl               ; 4 N
        ex de,hl                ; DE = 4 N, HL = list
        add iy,de
        pop de
        add hl,de
        inc hl
        inc hl                  ; after the list (N, attribute, 2 N bytes)
        ex de,hl
        ret
.changed:
        ld hl,(dsl_cur)
        ld a,(hl)
        or a
        jr z,.write
        push bc
        push de
        ld a,1
        ld (bgo_mode),a
        call dsl_quads          ; the old cells (the record still describes them)
        pop de
        pop bc
.write: ld hl,(dsl_cur)
        ld a,(ix+3)
        ld (hl),a
        inc l
        ld (hl),c
        inc l
        ld (hl),b
        inc l
        ld (hl),e
        inc l
        ld (hl),d
        inc l
        ld (hl),1
        push de
        xor a
        ld (bgo_mode),a
        call dsl_quads
        pop de
.hide:  ; the N sprite entries: Y = 0, attribute + y bit 8; IY, DE advance
        ld a,(de)
        ld b,a
        inc de
        ld a,(de)
        ld c,a
        inc de
.h:     ld a,(de)
        inc de
        inc de
        add a,a
        add a,a
        add a,a
        add a,a
        ld l,a
        ld h,0
        rlca
        rl h                    ; HL = y offset * 16, signed
        ld a,(ix+5)
        add a,l
        ld a,(ix+4)
        adc a,h
        and 1
        add a,c
        ld (iy+1),a
        ld (iy+2),0
        inc iy
        inc iy
        inc iy
        inc iy
        djnz .h
        ret

; the quads of the record (dsl_cur): (bgo_mode) 0 = write, 1 = clear. Maps the set's
; direct sprite table on page 1.
dsl_quads:
        ld a,(set_bank)
        add a,SET_DIRECT_BANKOFF
        ld (p1_cur),a
        ld (BANK_P1),a
        ld hl,(dsl_cur)
        ld a,(hl)
        ld (bgo_xa),a           ; x
        inc l
        ld e,(hl)
        inc l
        ld d,(hl)
        ld (bgo_cur),de         ; M (bgo_cur reused: 16-bit scratch)
        inc l
        ld a,(hl)
        inc l
        ld h,(hl)
        ld l,a                  ; HL = list
        ld b,(hl)               ; N
        inc hl
        ld a,(hl)
        ld (dsl_attr),a
        and 008h
        rrca
        rrca
        rrca
        ld (bgo_flip),a
        inc hl
.q:     push bc
        push hl
        ld a,(hl)               ; offset
        and 0F0h
        ld c,a
        ld a,(bgo_xa)
        add a,c
        ld (bgo_x),a            ; x of the quad
        ld a,(hl)
        add a,a
        add a,a
        add a,a
        add a,a
        ld e,a
        ld d,0
        rlca
        rl d                    ; DE = y offset * 16, signed
        ld hl,(bgo_cur)
        add hl,de
        ld a,h
        and 1
        ld d,a
        ld e,l                  ; DE = M of the quad
        pop hl
        inc hl
        ld c,(hl)               ; code
        inc hl
        push hl
        ; (ov_rec) = bgo_tmp: x, M
        ld hl,bgo_tmp
        ld (ov_rec),hl
        ld a,(bgo_x)
        ld (hl),a
        inc l
        ld (hl),e
        inc l
        ld (hl),d
        ld a,(dsl_attr)         ; write and clear alike: only the decoration quads (a list's
        rrca                    ; empty entries, code $FF at offset 0, lie on the other leaf
        rrca                    ; of the area gate: clearing them erased its cells)
        and 03Fh
        add a,040h
        ld h,a
        ld l,c
        ld a,(hl)               ; direct table: SPR_FIX + k
        cp SPR_FIX
        jr c,.next
        cp 0FDh
        jr nc,.next
        sub SPR_FIX
        ld e,a
        ld d,0
        ld hl,deco_sprite       ; a moving door (dugout, fortress): under its frame
        add hl,de
        ld b,(hl)
        add a,a
        ld hl,bgo_flip
        add a,(hl)
        ld c,a
        ld a,(bgo_mode)
        or a
        ld a,c
        jr nz,.clr
        inc b
        dec b
        jr nz,.under
        call deco_put_id
        jr .next
.under: call deco_under_id
        jr .next
.clr:   call deco_unput_id
.next:  pop hl
        pop bc
        djnz .q
        ret

; after the build: the records not drawn since the last sweep lose their cells
dsl_sweep:                      ; (not gated by dsl_any: a bridge whose object left the screen
        ld hl,dsl_rec           ; with no other static object drawing kept its cells, which the
        ld b,24                 ; wrapping name table showed again 512 px later)
.s:     push bc
        push hl
        ld a,(hl)
        or a
        jr z,.n
        ld a,l
        add a,5
        ld l,a
        ld a,(hl)
        or a
        jr z,.stale
        ld (hl),0
        jr .n
.stale: ld a,l
        sub 5
        ld l,a
        ld (dsl_cur),hl
        ld a,1
        ld (bgo_mode),a
        call dsl_quads
        ld hl,(dsl_cur)
        ld (hl),0
.n:     pop hl
        pop bc
        ld a,l
        add a,8
        ld l,a
        jr nc,.nc
        inc h
.nc:    djnz .s
        ret

; rewrite the cells of every record (after a text erase)
dsl_redraw:
        ld hl,dsl_rec
        ld b,24
.r:     push bc
        push hl
        ld a,(hl)
        or a
        jr z,.n
        ld (dsl_cur),hl
        xor a
        ld (bgo_mode),a
        call dsl_quads
.n:     pop hl
        pop bc
        ld a,l
        add a,8
        ld l,a
        jr nc,.nc
        inc h
.nc:    djnz .r
        ret

; after the build: the slots not drawn this frame lose their cells. Only
; when the hook ran since the last sweep: outside gameplay the arcade draws
; the structures once (map_set_position) and keeps the sprites.
bgo_sweep:
        ld hl,bgo_calls
        ld a,(hl)
        or a
        ret z
        ld (hl),0
        ld hl,bgo_rec
        ld b,9
.s:     push bc
        push hl
        ld a,l
        add a,5
        ld l,a
        ld a,(hl)
        or a
        jr z,.notseen
        cp 1
        jr nz,.n                ; a new structure took the slot (seen = 2): the update checks it
        ld (hl),0
        jr .n
.notseen:
        ld a,l
        sub 5
        ld l,a
        ld a,(hl)
        or a
        jr z,.n
        ld a,1
        ld (bgo_mode),a
        call bgo_quads
        ld hl,(bgo_cur)
        ld (hl),0
.n:     pop hl
        pop bc
        ld a,l
        add a,8
        ld l,a
        djnz .s
        ret

; rewrite the cells of every slot drawn (after a text erase)
bgo_redraw:
        ld hl,bgo_rec
        ld b,9
.r:     push bc
        push hl
        ld a,(hl)
        or a
        jr z,.n
        xor a
        ld (bgo_mode),a
        call bgo_quads
.n:     pop hl
        pop bc
        ld a,l
        add a,8
        ld l,a
        djnz .r
        ret

; After every 4th build: the records not seen since the last sweep (entry
; hidden, scrolled out of the visible range or reused by another sprite) lose
; their cells; the list is compacted. Uses AF, BC, DE, HL, IX.
ovl_sweep:
        ld a,(ovl_count)
        or a
        ret z
        ld b,a
        ld c,0                  ; records kept
        ld hl,ovl_list
        push hl
        pop ix                  ; write pointer
.s:     ld a,(hl)
        inc hl
        push hl
        push af
        call ovl_rec_of         ; HL = record
        ld (ov_rec),hl
        inc l
        inc l
        bit 7,(hl)              ; seen (M hi bit 7)
        jr z,.stale
        res 7,(hl)
        pop af
        ld (ix+0),a
        inc ix
        inc c
.next:  pop hl
        djnz .s
        ld a,c
        ld (ovl_count),a
        ret
.stale: pop af
        push bc
        call ovl_rec_unput
        ld hl,(ov_rec)
        ld (hl),0               ; no cells
        pop bc
        jr .next

; A = entry number (0-95) -> HL = its record
ovl_rec_of:
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld a,h
        add a,ovl_cache>>8
        ld h,a
        ret

; Sprite cache: H:L = key (H = bank | flip<<2 | pal<<4, L = code). 16 sets of
; 4 slots; a slot used by the current build is never evicted (the victim is
; the oldest way, else the next slot of the cache not used by this build).
; Returns A = SGT slot, C = palette block << 6. Uses BC, DE, HL.
spr_lookup_rom:
        phase spr_owner+SPR_FIX
spr_get_dyn:
        ld a,(tsm_on)           ; the text blocks of the pickup flight hold slots 212-239 (sets
        dec a                   ; 9-15): the hash then takes sets 0-7 only (the helicopter's
        and 8                   ; pieces landed in the reserved sets, were never found again
        or 7                    ; and refilled every build over slots still on screen)
        ld e,a
        ld a,h
        rrca
        rrca
        ld d,a
        ld a,l
        rrca
        xor l
        xor d
        and e                   ; hash (code ^ code >>> 1 ^ key >>> 2): 16 sets of 4 slots (SPR_DYNAMIC..239);
                                ; code ^ key put the frames of the helicopter in 2-4 sets
        rlca
        rlca
        rlca
        add a,(spr_owner+2*SPR_DYNAMIC)&255
        ex de,hl                ; DE = key
        ld l,a
        ld h,(spr_owner+2*SPR_DYNAMIC)>>8 ; HL = owner[first slot of the set] (the 16 sets lie in one page:
        sub (spr_owner+2*SPR_DYNAMIC)&255 ; owner[s] at spr_owner + 2 s, sets from slot SPR_DYNAMIC)
        rrca
        add a,SPR_DYNAMIC
        ld c,a                  ; first slot of the set
        ld b,4
.w:     ld a,(hl)
        cp e
        jr nz,.nx
        inc l
        ld a,(hl)
        cp d
        jr z,.hit
        dec l
.nx:    inc l
        inc l
        inc c
        djnz .w
        jp spr_cache_miss
.hit:   ld l,c
        ld h,spr_stamp>>8
        ld a,(build_no)
        ld (hl),a
        ld h,spr_blk_of>>8
        ld a,c
        ld c,(hl)               ; block << 6 remembered per slot
        ret
        dephase
spr_lookup_end:
        assert spr_owner+SPR_FIX+spr_lookup_end-spr_lookup_rom <= spat_buf
        assert spat_buf+28*4 <= spr_owner+2*SPR_DYNAMIC
        assert SPR_FIX+14 <= SPR_DYNAMIC
spr_cache_miss:
        ld hl,miss_count
        inc (hl)
        push de                 ; key
        ld a,c
        sub 4
        ld c,a                  ; the set's first slot
        ld a,(build_no)
        ld d,a
        ld e,0                  ; best age so far
        ld l,c
        ld h,spr_stamp>>8
        ld b,4
.v:     ld a,d
        sub (hl)                ; age: 0 = used by this build, 1 = by the previous one, whose
        cp 2                    ; SPAT may still be on screen (double-buffered): neither is a
        jr c,.vn                ; victim (rotor pieces of other frames showed for a frame)
        cp e
        jr c,.vn
        ld e,a
        ld c,l                  ; the oldest way so far
.vn:    inc l
        djnz .v
        ld a,e
        or a
        jr nz,.victim
        ld b,64                 ; every way in use: the next slot not used by the last two builds
.probe: inc l
        ld a,l
        cp 240
        jr c,.p2
        ld l,SPR_DYNAMIC
.p2:    ld a,d
        sub (hl)
        cp 2
        jr nc,.found
        djnz .probe
        ld b,64                 ; none: the next slot not used by this build
.probe2:
        inc l
        ld a,l
        cp 240
        jr c,.p3
        ld l,SPR_DYNAMIC
.p3:    ld a,d
        cp (hl)
        jr nz,.found
        djnz .probe2
.found: ld c,l
.victim:
        pop de
        ld l,c
        ld h,spr_stamp>>8
        ld a,(build_no)
        ld (hl),a
        ld l,c
        ld h,0
        add hl,hl
        push de
        ld de,spr_owner
        add hl,de
        pop de
        ld (hl),e
        inc hl
        ld (hl),d
        push bc
        call spr_fill           ; slot C := pattern of key DE; returns A = block<<6
        push af
        ld a,(set_bank)         ; cache fills change page 1, hits preserve the direct table
        add a,SET_DIRECT_BANKOFF
        ld (p1_cur),a
        ld (BANK_P1),a
        pop af
        pop bc
        ld l,c
        ld h,spr_blk_of>>8
        ld (hl),a
        ld a,c
        ld c,(hl)
        ret

; Fill SGT slot C with the pattern of key DE (E = code, D = bank|flip<<2|pal<<4).
; Atlas hit: LMMM from the atlas cell. Else: CPU upload from the raw ROM atlas.
; Returns A = block << 6. Uses all.
spr_fill:
        bit 7,d
        jp nz,spr_fill_deco
        push bc
        push de
        call set_idx_bank       ; the atlas index (spr_idx) is in the set's index bank
        ; sprite number = code + 256*bank
        ld a,d
        and 3
        ld h,a
        ld l,e
        add hl,hl
        ld bc,spr_idx
        add hl,bc
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        or h
        jr z,.fallback
        ld bc,spr_idx
        add hl,bc               ; list
        ld a,d
        rrca
        rrca
        and 00Fh                ; flip | pal<<2
        ld c,a
.l:     ld a,(hl)
        cp 0FFh
        jr z,.fallback
        cp c
        jr z,.found
        inc hl
        inc hl
        inc hl
        jr .l
.found: inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)               ; D = k hi | block<<4
        ld a,d
        and 030h
        rlca
        rlca                    ; block << 6
        push af
        ld a,d
        and 00Fh
        ld d,a                  ; DE = atlas cell k
        pop af
        pop hl                  ; (key, unused)
        pop bc                  ; C = slot
        push af
        call lmmm_cell
        pop af
        ret
.fallback:
        ld hl,fb_count
        inc (hl)
        pop de
        pop bc
        push bc
        ; raw variant index v = sprite*2 + (flip>>1 & 1); bank = BANK_RAW + v/128, offset (v%128)*128
        ld a,d
        and 3
        ld h,a
        ld l,e                  ; HL = sprite number (0-767)
        add hl,hl
        ld a,d
        and 008h                ; flip bit 1 (flip Y) is key bit 3
        jr z,.f0
        inc hl
.f0:    ld a,h                  ; v / 256 ... v = HL (0-1535): bank = v >> 7
        add a,a
        ld b,a
        ld a,l
        rlca
        and 1
        or b                    ; v >> 7
        add a,BANK_RAW
        ld (p1_cur),a
        ld (BANK_P1),a
        ld a,l
        and 07Fh
        ld h,a
        ld l,0
        srl h
        rr l                    ; (v % 128) * 128
        set 6,h                 ; + $4000
        pop bc                  ; C = slot
        push de
        ld a,d
        and 030h
        cp 010h                 ; palette 1: its pen 3 shares block 3 entry 4 with palette 3's
        ld a,0                  ; light green, so it is drawn with pen 8 (index 9)
        jr nz,.nrm
        inc a
.nrm:   ld (fb_remap),a
        ld a,d
        and 004h                ; flip X: the raw atlas only has the flip Y variants
        ld (fb_flipx),a
        call cpu_upload_slot    ; HL = source, C = slot
        pop de
        ld a,d
        and 030h                ; pal << 4
        cp 010h
        ld a,080h               ; block 2 (sprite palette 0)
        ret c
        ld a,0C0h               ; block 3 (palettes 1-3)
        ret

; HL = 8 bytes of a raw row -> fb_row with index 4 (palette 1 pen 3) -> 9; HL = fb_row.
; Uses AF, BC, DE.
fb_remap_row:
        ld de,fb_row
        ld b,8
.b:     ld a,(hl)
        inc hl
        ld c,a
        and 0F0h
        cp 040h
        jr nz,.lo
        ld a,c
        and 00Fh
        or 090h
        ld c,a
.lo:    ld a,c
        and 00Fh
        cp 004h
        jr nz,.st
        ld a,c
        and 0F0h
        or 009h
        ld c,a
.st:    ld a,c
        ld (de),a
        inc de
        djnz .b
        ld hl,fb_row
        ret

; LMMM: atlas cell DE -> SGT slot C (16x16). Waits for the command unit.
; Interrupts off around the register burst (the interrupt uses the ports).
lmmm_cell:
        call v9_wait
        di
        ld a,32
        out (V9_REGS),a
        ld a,e
        and 15
        rlca
        rlca
        rlca
        rlca                    ; SX = 16*(k%16)
        out (V9_REGD),a         ; R#32 SX low
        xor a
        out (V9_REGD),a         ; R#33
        ; SY = ATLAS_Y + 16*(k/16): k/16 = DE >> 4
        ld a,e
        and 0F0h
        ld l,a
        ld h,d                  ; HL = (k & ~15) ... as 16*(k/16) = k & ~15 (with D's bits above)
        ld de,ATLAS_Y
        add hl,de
        ld a,l
        out (V9_REGD),a         ; R#34 SY low
        ld a,h
        out (V9_REGD),a         ; R#35
        ld a,c
        and 15
        rlca
        rlca
        rlca
        rlca
        out (V9_REGD),a         ; R#36 DX low
        xor a
        out (V9_REGD),a         ; R#37
        ld a,c
        and 0F0h
        out (V9_REGD),a         ; R#38 DY low = 16*(slot/16)
        xor a
        out (V9_REGD),a         ; R#39
        call lmmm_16
        ei
        ret
; R#40-R#52 of a 16x16 LMMM (D = S) after R#32-R#39
lmmm_16:
        ld a,16
        out (V9_REGD),a         ; R#40 NX
        xor a
        out (V9_REGD),a
        ld a,16
        out (V9_REGD),a         ; R#42 NY
        xor a
        out (V9_REGD),a
        out (V9_REGD),a         ; R#44 ARG
        ld a,00Ch
        out (V9_REGD),a         ; R#45 LOP: D = S
        ld a,0FFh
        out (V9_REGD),a         ; R#46 WM
        xor a                   ; R#47: protect plane B for this plane A destination
        out (V9_REGD),a         ; R#47
        ld a,52
        out (V9_REGS),a
        ld a,040h
        out (V9_REGD),a         ; R#52: LMMM
        ret

; CPU upload: 128 bytes at HL (page 1) -> SGT slot C (16 rows of 8 bytes, 128 apart);
; fb_flipx: each row mirrored
cpu_upload_slot:
        ld a,1
        ld (vram_moved),a
        ld a,c
        and 0F0h
        ld d,a
        ld e,0
        srl d
        rr e                    ; (slot & $F0) * 128
        ld a,c
        and 15
        add a,a
        add a,a
        add a,a
        or e
        ld e,a                  ; DE = VRAM address (bits 15-0), bits 18-16 = 0
        ld b,16
.row:   push bc
        push hl
        push de
        ld a,(fb_flipx)
        or a
        jr z,.plain
        ld de,fb_row+7          ; mirrored row: bytes reversed, nibbles swapped
        ld b,8
.fx:    ld a,(hl)
        inc hl
        rrca
        rrca
        rrca
        rrca
        ld (de),a
        dec de
        djnz .fx
        ld hl,fb_row
.plain: ld a,(fb_remap)
        or a
        call nz,fb_remap_row
        pop de
        push de
        ex de,hl
        xor a
        di
        call v9_setw
        ex de,hl
        ld bc,8*256+V9_VRAM
        otir
        ei
        pop hl
        ld bc,128
        add hl,bc
        ex de,hl                ; DE = next VRAM row
        pop hl
        ld bc,8
        add hl,bc               ; next source row (the 16 rows of a sprite are contiguous)
        pop bc
        djnz .row
        ret

; =============================================================================
; HUD: the arcade HUD lines (text columns 31/30 at the top, 1/0 at the bottom)
; as 2x2-cell sprites composed from the font. Block b (0-27): rows
; r = 2 + 2*(b mod 14), cols (31,30) for b < 14, (1,0) otherwise.
; Fixed SGT patterns: 240-253 at the top, SPR_FIX..SPR_FIX+13 at the bottom.
; The compact SPAT prefix is rebuilt only when the visible blocks change.
; =============================================================================
hud_update:
        xor a
        ld (hud_dirty),a
        ld b,0                  ; block
.blk:   push bc
        ld hl,hud_blk_dirty     ; only the blocks written since their last compose
        ld a,b
        add a,l
        ld l,a
        ld a,(hl)
        or a
        jp z,.same
        ld (hl),0
        ld a,b
        cp 14
        ld c,31                 ; first column (top)
        jr c,.top
        sub 14
        ld c,1                  ; bottom
.top:   add a,a
        add a,2                 ; row r
        ; cell addresses: (r, c), (r+1, c), (r, c-1), (r+1, c-1)
        ld h,0
        ld l,a
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; r*32
        ld a,l
        or c
        ld l,a
        ld a,h
        or TXT_CODE>>8
        ld h,a                  ; HL = cell (r, c)
        ld (hud_hl),hl
        pop bc
        push bc
        ; compare the 4 codes with hud_cells[b]
        ld a,b
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld ix,hud_cells
        add ix,de
        ld a,(hl)
        ld d,a                  ; TL
        ld e,0                  ; any non-blank?
        cp 020h
        jr z,.t1
        ld e,1
.t1:    cp (ix+0)
        jr nz,.changed
        push hl
        ld bc,32
        add hl,bc
        ld a,(hl)               ; TR (r+1, c)
        cp 020h
        jr z,.t2
        ld e,1
.t2:    cp (ix+1)
        jr nz,.changed_p
        dec l                   ; (r+1, c-1) = BR
        ld a,(hl)
        cp 020h
        jr z,.t3
        ld e,1
.t3:    cp (ix+3)
        jr nz,.changed_p
        pop hl
        dec hl
        ld a,(hl)               ; BL (r, c-1)
        cp 020h
        jr z,.t4
        ld e,1
.t4:    cp (ix+2)
        jr nz,.changed
        jr .same
.changed_p:
        pop hl
.changed:
        ; recompose: store the 4 codes, compose or free
        ld hl,(hud_hl)
        ld a,(hl)
        ld (ix+0),a
        ld e,0
        cp 020h
        jr z,.c1
        inc e
.c1:    push hl
        ld bc,32
        add hl,bc
        ld a,(hl)
        ld (ix+1),a
        cp 020h
        jr z,.c2
        inc e
.c2:    dec l
        ld a,(hl)
        ld (ix+3),a
        cp 020h
        jr z,.c3
        inc e
.c3:    pop hl
        dec hl
        ld a,(hl)
        ld (ix+2),a
        cp 020h
        jr z,.c4
        inc e
.c4:    pop bc
        push bc
        ld a,e
        or a
        jr z,.free
        call hud_compose        ; block B -> its dedicated slot
        jr .same
.free:  ld hl,hud_slot
        ld a,b
        add a,l
        ld l,a
        ld (hl),0FFh
        ld a,1
        ld (hud_spat_dirty),a
.same:  pop bc
        inc b
        ld a,b
        cp 28
        jp nz,.blk
        ; SPAT prefix of the nonblank blocks, when a slot changed or the
        ; game state did (the bottom band only shows during a game)
        ld a,(arc_game_state)
        cp 3
        ld a,0
        jr nz,.st
        inc a
.st:    ld hl,hud_state_last
        cp (hl)
        ld (hl),a
        jr nz,.redo
        ld a,(hud_spat_dirty)
        or a
        ret z
.redo:  xor a
        ld (hud_spat_dirty),a
        ld iy,spat_buf
        ld c,0                  ; entries written
        ld b,0
.spat:  ld hl,hud_slot
        ld a,b
        add a,l
        ld l,a
        ld a,(hl)
        cp 0FFh
        jr z,.ns
        ld e,a
        ld a,b
        cp 14
        jr c,.shown
        ld a,(arc_game_state)
        cp 3
        jr nz,.ns               ; bottom band only during a game (the title has text there)
        ld a,(txt_shift)
        or a
        jr nz,.ns               ; and while the text is not moved up (then plane A shows it)
.shown: ld a,e
        ld (iy+1),a
        ld a,b
        cp 14
        ld e,0FFh               ; top band: line 0 -> Y = -1
        jr c,.band
        sub 14
        ld e,196-1
.band:  ld (iy+0),e
        add a,a
        add a,2                 ; row r
        add a,a
        add a,a
        add a,a                 ; x = 8r
        ld (iy+2),a
        ld (iy+3),040h          ; block 1, P = 0, in front
        inc iy
        inc iy
        inc iy
        inc iy
        inc c
.ns:    inc b
        ld a,b
        cp 28
        jr nz,.spat
        ld a,c
        ld (hud_count),a
        ret

; Each block has its own pattern even when every other HUD block is visible.
hud_compose:
        ld hl,hud_slot
        ld a,b
        add a,l
        ld l,a
        ld a,(hl)
        cp 0FFh
        jr nz,.have
        ld a,b
        cp 14
        jr c,.upper
        add a,SPR_FIX-14
        jr .new
.upper: add a,240
.new:   ld (hl),a
        ld c,a
        ld a,1
        ld (hud_spat_dirty),a
        ld a,c
.have:  ld c,a                  ; slot
        ld hl,(hud_hl)
        ; TL (r, c) -> (0, 0); TR (r+1, c) -> (8, 0); BL (r, c-1) -> (0, 8); BR (r+1, c-1) -> (8, 8)
        ld d,0
        ld e,0
        call .cell
        ld hl,(hud_hl)
        ld de,32
        add hl,de
        ld d,8
        ld e,0
        call .cell
        ld hl,(hud_hl)
        dec hl
        ld d,0
        ld e,8
        call .cell
        ld hl,(hud_hl)
        ld de,31
        add hl,de
        ld d,8
        ld e,8
        ; fall through
.cell:  ; HL = text cell, D = dx, E = dy, C = slot: LMMM font pattern -> slot + (dx, dy)
        push bc
        push de
        ld a,(hl)
        push hl
        set 2,h
        ld b,(hl)               ; attribute
        pop hl
        ld c,a                  ; code
        push hl
        call font_lookup        ; DE = pattern
        pop hl
        pop hl                  ; H = dx, L = dy
        pop bc
        push bc
        call lmmm_pat
        pop bc
        ret

; LMMM plane A pattern DE -> SGT slot C at (H = dx, L = dy) of its 16x16 cell.
; Keeps BC, DE, HL.
lmmm_pat:
        push de
        push hl
        ; source: x = 8*(n%32), y = 8*(n/32)
        call v9_wait
        di
        ld a,32
        out (V9_REGS),a
        ld a,e
        and 31
        add a,a
        add a,a
        add a,a
        out (V9_REGD),a         ; SX
        ld a,(lp_sxh)
        out (V9_REGD),a
        pop hl                  ; H = dx, L = dy
        ; SY = 8*(n/32) = (n >> 2) & ~7
        ld a,e
        rrca
        rrca
        and 03Fh
        ld e,a
        ld a,d
        rrca
        rrca
        and 0C0h
        or e
        and 0F8h
        out (V9_REGD),a         ; SY low
        ld a,d
        rrca
        rrca
        and 03Fh
        out (V9_REGD),a         ; SY high
        ld a,c
        and 15
        rlca
        rlca
        rlca
        rlca
        add a,h                 ; DX = 16*(slot%16) + dx
        out (V9_REGD),a
        xor a
        out (V9_REGD),a
        ld a,c
        and 0F0h
        add a,l                 ; DY = 16*(slot/16) + dy
        out (V9_REGD),a
        xor a
        out (V9_REGD),a
        ld a,8
        out (V9_REGD),a         ; NX
        xor a
        out (V9_REGD),a
        ld a,8
        out (V9_REGD),a         ; NY
        xor a
        out (V9_REGD),a
        out (V9_REGD),a         ; ARG
        ld a,00Ch
        out (V9_REGD),a         ; LOP
        ld a,0FFh
        out (V9_REGD),a
        xor a                   ; R#47: protect plane B for this plane A destination
        out (V9_REGD),a         ; WM
        ld a,52
        out (V9_REGS),a
        ld a,040h
        out (V9_REGD),a
        ei
        pop de
        ret

; =============================================================================
; Inputs: keyboard + joystick 1 -> IO_P1 / IO_SYSTEM (active low).
; Cursor keys / stick = move, SPACE / Z / trigger A = fire, M / X / trigger B
; = grenade, P = pause (in a game). On the attract screens a new press of fire or key 1 reports START1 and
; one of grenade or key 2 START2, for 4 frames; no coins (hook_start starts the game).
; =============================================================================
read_input:
        ld a,4                  ; P (a new press, in a game): pause / resume
        call kbd_row
        and 020h
        ld hl,pause_prev
        ld b,(hl)
        ld (hl),a
        jr nz,.np
        ld a,b
        or a
        jr z,.np
        ld a,(arc_game_state)
        cp 3
        jr nz,.np
        ld a,(paused)
        xor 1
        ld (paused),a
.np:    ld c,0                  ; P1 bits, active high: 0 R 1 L 2 D 3 U 4 fire 5 grenade
        ld a,8
        call kbd_row
        bit 7,a
        jr nz,$+4
        set 0,c                 ; right
        bit 4,a
        jr nz,$+4
        set 1,c                 ; left
        bit 6,a
        jr nz,$+4
        set 2,c                 ; down
        bit 5,a
        jr nz,$+4
        set 3,c                 ; up
        bit 0,a
        jr nz,$+4
        set 4,c                 ; space
        ld a,5
        call kbd_row
        bit 7,a
        jr nz,$+4
        set 4,c                 ; Z
        bit 5,a
        jr nz,$+4
        set 5,c                 ; X
        ld a,4
        call kbd_row
        bit 2,a
        jr nz,$+4
        set 5,c                 ; M
        ld a,15
        out (0A0h),a
        in a,(0A2h)
        and 0BFh
        out (0A1h),a
        ld a,14
        out (0A0h),a
        in a,(0A2h)             ; joystick 1: 0 U 1 D 2 L 3 R 4 A 5 B (active low)
        bit 0,a
        jr nz,$+4
        set 3,c
        bit 1,a
        jr nz,$+4
        set 2,c
        bit 2,a
        jr nz,$+4
        set 1,c
        bit 3,a
        jr nz,$+4
        set 0,c
        bit 4,a
        jr nz,$+4
        set 4,c
        bit 5,a
        jr nz,$+4
        set 5,c
        ld a,c
        cpl
        ld (IO_P1),a
        ; ---- start: fire / key 1 = START1 (normal game), grenade / key 2 = START2 (easy game)
        ld a,c
        rrca
        rrca
        rrca
        rrca
        and 3                   ; b0 fire, b1 grenade
        ld e,a
        xor a
        call kbd_row            ; row 0: b1 key 1, b2 key 2 (0 = pressed)
        cpl
        rrca
        and 3
        or e
        ld e,a
        ld a,(start_prev)
        cpl
        and e
        ld d,a                  ; buttons newly pressed
        ld a,e
        ld (start_prev),a
        ld a,d
        or a
        jr z,.hold
        ld a,(arc_game_state)   ; only on the attract screens (the arcade's attract_common reads it)
        dec a
        jr nz,.hold
        ld a,d
        and 1
        jr nz,.s1               ; both: START1
        ld a,2
.s1:    ld (start_bits),a
        ld a,4
        ld (start_hold),a
.hold:  ld c,0FFh
        ld a,(start_hold)
        or a
        jr z,.nostart
        dec a
        ld (start_hold),a
        ld a,(start_bits)
        cpl
        ld c,a
.nostart:
        ld a,c
        ld (IO_SYSTEM),a
        ret

kbd_row:
        ld b,a
        in a,(0AAh)
        and 0F0h
        or b
        out (0AAh),a
        in a,(0A9h)
        ret

; =============================================================================
; data
; =============================================================================
deco_sprite:                    ; decoration k -> 1: drawn as a sprite when it comes through the sprite entries
        incbin "../build/port/assets/deco_sprite.bin"
        include "../build/port/sound_tabs.inc"   ; sound driver tables (tools/gen_sound.py)

ovl_end:
        ds 0BF00h-$,0FFh        ; (the page-aligned table in the last page: no alignment gap)
ovl_k2p3:                       ; bank 2 palette 3 sprite code -> decoration k ($FF none)
        incbin "../build/port/assets/ovl_k2p3.bin"
