; =============================================================================
; Commando for MSX turbo R + V9990: ROM header and boot (bank 0, mapped at $4000)
;
; 1. MSX turbo R check (else a message and stop), "V9990 found" banner in
;    SCREEN 0 with the BIOS (still on page 0), R800 in DRAM mode
; 2. find the cartridge slot (page 1) and map it on page 2 too; the DiHalt logo
;    (B1, 10 s with MoonSound or 4 s silent) and the cover picture (B3) until fire; F1 held: immunity trick
; 3. select RAM for page 0, preferring the turbo R's internal mapper
; 4. install the resident runtime at $C000 and the arcade at $0000-$3FFF.
;    Cache its upper code bank and the V9990 overlay in internal mapper RAM
;    when two independent segments are available for page 2
; 5. V9990: P1 mode, palettes, font, sprite atlas, blank name tables, margins
; 6. arcade I/O defaults, IM 2, V9990 vertical interrupt on, jump to the
;    arcade reset at $0000 (which clears its RAM and enables interrupts)
; =============================================================================
        include "common.inc"
        include "../build/port/resident.inc"
        include "../build/port/banks.inc"

ENASLT          equ 00024h
RSLREG          equ 00138h
EXPTBL          equ 0FCC1h
INITXT          equ 0006Ch
ENASCR          equ 00044h
CLS             equ 000C3h
POSIT           equ 000C6h
CHPUT           equ 000A2h
CHGCPU          equ 00180h      ; turbo R BIOS: A = 0 Z80, 1 R800 ROM, 2 R800 DRAM; b7 = turbo LED
MSXVER          equ 0002Dh      ; BIOS: 0 MSX1, 1 MSX2, 2 MSX2+, 3 turbo R
CLIKSW          equ 0F3DBh      ; BIOS keyboard click
GTTRIG          equ 000D8h      ; BIOS: A = 0 space, 1/2 joystick button 1 -> A = $FF pressed
SNSMAT          equ 00141h      ; BIOS: A = keyboard row -> A (bit = 0: key down)

        org 04000h
        db "AB"
        dw boot
        ds 12,0

boot:
        di
        ld sp,0F380h
        xor a
        ld (CLIKSW),a
        call INITXT
        xor a
        ld (CLIKSW),a
        call CLS
        call ENASCR
        ld hl,txt_credits
        call print_z
        ld a,(MSXVER)           ; MSX turbo R only (the game needs the R800)
        cp 3
        jr nc,.turbo_r
        ld hl,txt_not_tr
        call print_z
        jr $
.turbo_r:
        call v9_detect
        jr z,.v9_found
        ld hl,00118h
        call POSIT
        ld hl,txt_not_found
        call print_z
        jr $
.v9_found:
        ld hl,txt_found
        call print_z
        ld b,120                ; 2 s
.v9_wait:
        in a,(099h)
        rlca
        jr nc,.v9_wait
        djnz .v9_wait
        ; ---- R800 (DRAM mode, turbo LED on) while the BIOS is still here
        ld a,082h
        call CHGCPU
        ; ---- cartridge slot (page 1) -> page 2
        call RSLREG
        rrca
        rrca
        and 3
        ld c,a
        ld b,0
        ld hl,EXPTBL
        add hl,bc
        ld a,(hl)
        and 080h
        or c
        ld c,a
        jp p,.cart_ok
        inc hl
        inc hl
        inc hl
        inc hl
        ld a,(hl)               ; SLTTBL
        and 00Ch
        or c
        ld c,a
.cart_ok:
        ld a,c
        ld (boot_cart_slot),a
        ld h,080h
        call ENASLT
        di
        ; ---- TMS9918: no interrupts, display off, black backdrop
        ld a,080h
        out (099h),a
        ld a,081h
        out (099h),a
        ld a,001h
        out (099h),a
        ld a,087h
        out (099h),a
        in a,(099h)
        ; ---- the DiHalt logo, then the cover until fire (with F1 held: immunity trick)
        call logo_show
        call opening_show
        ; ---- find a RAM slot: test page 2 of every slot/subslot
        ; The turbo R's internal mapper is in slot 3-0. Prefer its fast RAM even
        ; when an expansion in an earlier slot answers this write test.
        ld a,083h
        call ram_test_slot
        jr z,.ram_found
        ld b,0
.ram_prim:
        ld hl,EXPTBL
        ld a,l
        add a,b
        ld l,a
        ld a,(hl)
        and 080h
        jr z,.ram_try1
        ld e,0
.ram_sub:
        ld a,e
        rlca
        rlca
        or 080h
        or b
        call ram_test_slot
        jr z,.ram_found
        inc e
        ld a,e
        cp 4
        jr nz,.ram_sub
        jr .ram_next
.ram_try1:
        ld a,b
        call ram_test_slot
        jr z,.ram_found
.ram_next:
        inc b
        ld a,b
        cp 4
        jr nz,.ram_prim
        di
        jr $                    ; no RAM
.ram_found:
        ld (boot_ram_slot),a
        ld a,(boot_cart_slot)
        ld h,080h
        call ENASLT             ; cartridge back on page 2
        di
        ; ---- page 0 := the RAM slot (expanded: its subslot register with page 3 in that slot)
        ld a,(boot_ram_slot)
        and 3
        ld c,a
        ld a,(boot_ram_slot)
        rrca
        rrca
        and 3
        ld e,a
        ld a,(boot_ram_slot)
        bit 7,a
        jr z,.prim
        in a,(0A8h)
        ld d,a
        and 03Fh
        ld b,a
        ld a,c
        rrca
        rrca
        or b
        out (0A8h),a            ; page 3 -> RAM primary slot
        ld a,(0FFFFh)
        cpl
        and 0FCh
        or e
        ld (0FFFFh),a           ; page 0 subslot
        ld a,d
        out (0A8h),a
.prim:  in a,(0A8h)
        and 0FCh
        or c
        out (0A8h),a            ; page 0 = RAM
        ; A RAM expansion (including the mapper in a MegaFlashROM) can be
        ; the BIOS work RAM in page 3. The arcade keeps all its actors, its
        ; stack and the resident handlers here. Move the game to fast internal
        ; RAM before installing any of them. Only the launch options survive
        ; BIOS takeover. No stack access while switching away from the old RAM.
        ld a,(boot_ram_slot)
        cp 083h
        jr nz,.page3_ready
        in a,(0A8h)
        and 0C0h
        cp 0C0h
        jr nz,.move_page3
        ld a,(0FFFFh)
        cpl
        and 0C0h
        jr z,.page3_ready       ; page 3 is already the internal RAM (3-0)
.move_page3:
        ld a,3
        out (0FCh),a            ; page 0 is internal scratch, distinct from segment 0
        ld hl,0CFF0h
        ld de,00000h
        ld bc,16
        ldir
        xor a
        out (0FFh),a            ; page 3 segment 0 (this may unmap the old stack)
        in a,(0A8h)
        or 0C0h
        out (0A8h),a
        ld a,(0FFFFh)
        cpl
        and 03Fh                ; page 3 -> secondary 0; keep page 0/1/2 assignments
        ld (0FFFFh),a
        ld hl,00000h
        ld de,0CFF0h
        ld bc,16
        ldir
.page3_ready:
        ; ---- resident runtime image (in this bank) -> $C000-$CFFF
        ld hl,resident_image
        ld de,0C000h
        ld bc,00FF0h            ; not $CFF0-$CFFF: boot variables (cheat_kill)
        ldir
        ld sp,0F000h            ; boot stack in the arcade's RAM (its reset sets its own; $CFxx is resident code)
        call load_program_pages
        ; ---- V9990 set-up and the global uploads (code in the overlay bank)
        ld a,BANK_OVL
        call set_p2
        ld a,BANK_ARC1
        ld (p1_cur),a           ; (page 1 still holds this boot bank until the end)
        call 08000h             ; ovl_boot_init: V9990 + uploads + variables (returns with page 1 = boot bank)
        ; ---- arcade I/O defaults
        ld a,0FFh
        ld (IO_SYSTEM),a
        ld (IO_P1),a
        ld (IO_P2),a
        ld a,0FFh               ; DSW1: 1 coin 1 credit, 3 lives, start area 0
        ld (IO_DSW1),a
        ld a,01Fh               ; DSW2: bonus 10K/50K, demo sounds on, normal, no flip, upright
        ld (IO_DSW2),a
        xor a
        ld (IO_SCROLLX_LO),a
        ld (IO_SCROLLX_HI),a
        ld (IO_SCROLLY_LO),a
        ld (IO_SCROLLY_HI),a
        ; ---- IM 2 + banks for the arcade, then its reset
        ld a,IM2_TABLE>>8
        ld i,a
        im 2
        ld a,7
        out (V9_INT),a          ; clear pending flags
        ld a,9
        out (V9_REGS),a
        ld a,1
        out (V9_REGD),a         ; R#9: vertical interrupt enable
        ld a,BANK_ARC2
        call set_p2
        jp boot_go              ; resident: page 1 := arcade bank, jp $0000

; The ARC2 and overlay banks are the only banks executed in page 2 after
; boot. Their instruction fetches are much faster from internal mapper RAM
; than through an external cartridge slot. Page 1 remains the ASCII16 asset
; window. Page 0 is scratch until the last copy installs the arcade reset.
load_program_pages:
        xor a
        ld (code_in_ram),a
        ld a,(boot_ram_slot)
        cp 083h
        jr nz,.arc0
        ld a,(boot_cart_slot)
        and 3
        cp 3                    ; cannot switch these two subslots by primary alone
        jr z,.arc0
        in a,(0A8h)
        ld (boot_p2_cart),a
        or 030h                 ; primary 3 for page 2, already subslot 0 (RAM test)
        ld (boot_p2_ram),a
        out (0A8h),a
        ; Check that both segments are independently writable and neither
        ; aliases page 0 or the resident/stack in page 3. Restore both probe
        ; bytes even on a machine whose mapper does not support this layout.
        ld a,(00080h)
        push af
        ld a,(0C080h)
        push af
        xor a
        ld (00080h),a
        ld (0C080h),a
        ld hl,08080h
        ld a,BANK_ARC2+CODE_SEG_OFS
        out (0FEh),a
        ld (hl),055h
        ld a,BANK_OVL+CODE_SEG_OFS
        out (0FEh),a
        ld (hl),0AAh
        ld a,(hl)
        cp 0AAh
        jr nz,.tested
        ld a,BANK_ARC2+CODE_SEG_OFS
        out (0FEh),a
        ld a,(hl)
        cp 055h
        jr nz,.tested
        ld a,(00080h)
        ld hl,0C080h
        or (hl)
        jr nz,.tested
        inc a
        ld (code_in_ram),a
.tested:
        pop af
        ld (0C080h),a
        pop af
        ld (00080h),a
        ld a,(boot_p2_cart)
        out (0A8h),a
        ld a,(code_in_ram)
        or a
        jr z,.arc0
        ld a,BANK_ARC2
        call .cache
        ld a,BANK_OVL
        call .cache
.arc0:  ld a,BANK_ARC0
        call .to_page0
        ld a,(code_in_ram)
        or a
        ret z
        ld a,(boot_p2_ram)
        out (0A8h),a
        ret
.cache: push af
        call .to_page0
        pop af
        add a,CODE_SEG_OFS
        out (0FEh),a
        ld a,(boot_p2_ram)
        out (0A8h),a
        ld hl,00000h
        ld de,08000h
        ld bc,04000h
        ldir
        ld a,(boot_p2_cart)
        out (0A8h),a
        ret
.to_page0:
        ld (BANK_P2),a
        ld hl,08000h
        ld de,00000h
        ld bc,04000h
        ldir
        ret

; ---------------------------------------------------------------- start-up pictures
; DiHalt Studio logo: B1 bitmap (256x212, 4 bpp) with the optional OPL4 fanfare. Banks BANK_LOGO and BANK_LOGO+1 (tools/build_opening.py).
logo_show:
        ld a,2
        out (V9_SYS),a
        xor a
        out (V9_SYS),a
        ld a,8
        out (V9_REGS),a
        ld a,002h               ; R#8 immediately after reset: 512 KiB, display off
        out (V9_REGD),a
        xor a                   ; R#9: no interrupts
        out (V9_REGD),a
        call v9_picture_regs
        db 081h                 ; R#6: bitmap, 256 pixels per line, 4 bpp
        db 000h                 ; R#7: 212 lines, no interlace, NTSC
        db 000h                 ; R#13: palette colours
        ; Keep the B3 opening in bitmap VRAM at $00000. The B1 logo uses
        ; $40000 (row 2048 at 128 bytes/row); both modes use the same VRAM wiring.
        ld a,BANK_OPENING
        ld de,848               ; 217088 bytes = 512 x 424
        call v9_upload
        ld a,0                  ; R#0..2: VRAM write pointer $40000
        out (V9_REGS),a
        out (V9_REGD),a
        out (V9_REGD),a
        ld a,4
        out (V9_REGD),a
        ld a,18                 ; SCAY high: display the logo from row 2048
        out (V9_REGS),a
        ld a,8
        out (V9_REGD),a
        ld a,BANK_LOGO
        ld de,106               ; 27136 bytes
        call v9_upload
        ld a,BANK_LOGO+1
        ld (BANK_P2),a
        ld a,14                 ; R#14: palette pointer 0
        out (V9_REGS),a
        xor a
        out (V9_REGD),a
        ld hl,08000h+16128      ; 16 entries (R, G, B) at the end of the second bank
        call v9_wait_frame
        ld bc,48*256+V9_PAL
        otir
        call fanfare_prepare
        push af                 ; carry: no OPL4
        call v9_display_on
        pop af
        jr c,.silent
        call fanfare_play
        jp wait_release
.silent:
        ld bc,240               ; 240 frames = 4 s at 60 Hz
.frame: call v9_wait_frame
        dec bc
        ld a,b
        or c
        jr nz,.frame
        jr wait_release         ; a key held during the logo must not skip the cover

; The cover: B3 in BD8 (fixed RGB332 colours), 512x424 interlaced, until fire (space or a
; joystick button). F1 held at that moment (or while fire is let go) sets the hidden immunity
; trick: cheat_kill := $FF, the kill requests of shots and contacts leave the player alive.
opening_show:
        xor a
        ld (opening_pressed),a
        ld (easy_adj),a         ; normal until a game is started (START2: easy)
        ld a,03Fh
        ld (cheat_kill),a
        call v9_picture_regs
        db 096h                 ; R#6: bitmap, 512 pixels per line, 8 bpp
        db 006h                 ; R#7: EO=1, IL=1 (424 lines), NTSC
        db 040h                 ; R#13: BD8
        ld a,18                 ; SCAY high: opening at row 0
        out (V9_REGS),a
        xor a
        out (V9_REGD),a
        call v9_display_on
        ld a,(pcm_ready)
        or a
        jr z,.wait
        xor a
        ld (pcm_ready),a        ; upload failure keeps the PSG fallback
        call pcm_prepare        ; cover stays visible during the effects upload
        ld a,(opening_pressed)
        or a
        jr nz,wait_release
.wait:  call fire_pressed
        jr z,.wait
        call poll_cheat
wait_release:                   ; up to 30 frames for fire to be let go (held: the arcade starts sooner)
        ld b,30
.rel:   call v9_wait_frame
        call fire_pressed
        jr z,.off
        call poll_cheat
        djnz .rel
.off:   call v9_wait_frame
        ld a,0C8h               ; lock R#8 for read and write
        out (V9_REGS),a
        in a,(V9_REGD)
        and 07Fh
        out (V9_REGD),a
        ret

; Notice taps while the cartridge is filling its sample RAM. The BIOS
; calls may use the transfer registers. Preserve the fire/F1 combination
; even if the player releases it before the upload finishes.
opening_poll:
        ld a,(opening_pressed)
        or a
        ret nz
        push bc
        push de
        push hl
        push ix
        call fire_pressed
        jr z,.done
        ld a,1
        ld (opening_pressed),a
        call poll_cheat
.done:  pop ix
        pop hl
        pop de
        pop bc
        ret

; NZ = space or a joystick button. Keeps BC (GTTRIG does not: each result goes on the stack).
fire_pressed:
        push bc
        xor a
        call GTTRIG
        push af
        ld a,1
        call GTTRIG
        pop bc
        or b
        push af
        ld a,2
        call GTTRIG
        pop bc
        or b
        pop bc
        ret

; F1 (keyboard row 6, bit 5 = 0) held: the immunity trick. Keeps B.
poll_cheat:
        push bc
        ld a,6
        call SNSMAT
        pop bc
        bit 5,a
        ret nz
        ld a,0FFh
        ld (cheat_kill),a
        ret

; Configure a bitmap while display is off: R#6/R#7/R#13 from the three bytes
; after the call, black border, VRAM write pointer 0. Keep the opening in
; VRAM across the mode change and preserve R#8's RAM and display bits.
v9_picture_regs:
        pop hl
        ld a,6
        out (V9_REGS),a
        ld a,(hl)
        inc hl
        out (V9_REGD),a         ; R#6
        ld a,(hl)
        inc hl
        out (V9_REGD),a         ; R#7
        ld a,13
        out (V9_REGS),a
        ld a,(hl)
        inc hl
        out (V9_REGD),a         ; R#13
        push hl
        ld a,15                 ; R#15: border = palette entry 0, black (the reset leaves it white)
        out (V9_REGS),a
        xor a
        out (V9_REGD),a
        ld a,14
        out (V9_REGS),a
        xor a
        out (V9_REGD),a
        call v9_wait_frame
        xor a
        out (V9_PAL),a
        out (V9_PAL),a
        out (V9_PAL),a
        xor a                   ; VRAM write pointer 00000h (R#0-R#2)
        out (V9_REGS),a
        out (V9_REGD),a
        out (V9_REGD),a
        out (V9_REGD),a
        ret

; DE x 256 bytes from bank A on (page 2, consecutive banks) to the VRAM write pointer.
v9_upload:
        ld (BANK_P2),a
        ld hl,08000h
        ld bc,V9_VRAM
.blk:   otir                    ; B = 0: 256 bytes
        dec de
        ld b,a                  ; (B = 0 again below)
        ld a,d
        or e
        ld a,b
        ld b,0
        ret z
        bit 6,h                 ; HL reached $C000: the next bank
        jr z,.blk
        inc a
        jr v9_upload

; Publish the completed bitmap at a fresh VBlank, preserving the other R#8 bits.
v9_display_on:
        call v9_wait_frame
        ld a,0C8h
        out (V9_REGS),a
        in a,(V9_REGD)
        or 080h
        out (V9_REGD),a
        ret
; Wait for the start of the next vertical retrace (P#5 b6). Keeps BC.
v9_wait_frame:
        in a,(V9_STAT)
        bit 6,a
        jr nz,v9_wait_frame
.r:     in a,(V9_STAT)
        bit 6,a
        jr z,.r
        ret

opening_pressed: equ 0CFF6h     ; fire latched during the opening PCM upload
boot_cart_slot: equ 0CFF8h
boot_ram_slot:  equ 0CFF9h
boot_p2_cart:   equ 0CFFDh
boot_p2_ram:    equ 0CFFEh

; A = slot ID: map it on page 2 and test RAM at $BFFF. Z = RAM. Keeps B, E.
ram_test_slot:
        push bc
        push de
        push af
        ld h,080h
        call ENASLT
        di
        ld hl,0BFFFh
        ld a,(hl)
        cpl
        ld (hl),a
        cp (hl)
        cpl
        ld (hl),a
        pop bc
        ld a,b
        pop de
        pop bc
        ret

; Z = a V9990 answers (register 15 keeps what is written)
v9_detect:
        ld a,15
        out (V9_REGS),a
        ld a,02Ah
        out (V9_REGD),a
        ld a,15
        out (V9_REGS),a
        in a,(V9_REGD)
        and 03Fh
        cp 02Ah
        ret nz
        ld a,15
        out (V9_REGS),a
        ld a,015h
        out (V9_REGD),a
        ld a,15
        out (V9_REGS),a
        in a,(V9_REGD)
        and 03Fh
        cp 015h
        ret nz
        ld a,15
        out (V9_REGS),a
        xor a
        out (V9_REGD),a
        ret

print_z:
        ld a,(hl)
        or a
        ret z
        inc hl
        push hl
        call CHPUT
        pop hl
        jr print_z

txt_credits:    db "CAPCOM 1985",13,10,"DIHALT STUDIO 2026",13,10,"VERSION 1.0",13,10,13,10,0
txt_found:      db "V9990 found!",0
txt_not_found:  db "V9990 NOT found!",0
txt_not_tr:     db "THIS GAME RUNS ONLY ON MSX TURBO R",0

        include "logo_fanfare.inc"

        align 256
resident_image:
        incbin "../build/port/resident.bin"
