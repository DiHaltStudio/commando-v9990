; DiHalt's dihalt34, using the MoonSound stream and RAM image from HeroQuest.
; Boot bank in page 1, samples or stream in page 2. Interrupts stay disabled.
; Wait for BUSY and LD (instrument-header load). Carry on timeout or open bus.
fanfare_ready:
        push hl
        ld hl,2048
.poll:  in a,(0C4h)
        and 3
        jr z,.done
        dec hl
        ld a,h
        or l
        jr nz,.poll
        scf
.done:  pop hl
        ret

; C = address port, D = register, E = value. Preserve BC, DE and HL.
fanfare_write:
        call fanfare_ready
        ret c
        out (c),d
        call fanfare_ready
        ret c
        inc c
        out (c),e
        dec c
        ret

; Read wave register D. Return value in A and carry clear on success.
fanfare_read:
        call fanfare_ready
        ret c
        ld a,d
        out (07Eh),a
        call fanfare_ready
        ret c
        in a,(07Fh)
        ret

; A group's count is in B; HL advances past its port/register/value triples.
fanfare_group:
        ld c,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld e,(hl)
        inc hl
        call fanfare_write
        ret c
        djnz fanfare_group
        ret

; Detect the YMF278B and preload its sample RAM before making the logo visible.
fanfare_prepare:
        xor a
        ld (pcm_ready),a
        ld c,0C6h
        ld de,00503h            ; FM 105h: NEW + NEW2
        call fanfare_write
        ret c
        ld d,2
        call fanfare_read
        ret c
        and 0E0h
        cp 020h                 ; wave chip ID
        jr z,.opl4
        scf
        ret
.opl4:  ld hl,.address
        ld b,4
        call fanfare_group
        ret c
        call fanfare_ready
        ret c
        ld a,6
        out (07Eh),a            ; memory data register, auto-increment address
        ld a,BANK_FANFARE_PCM
        ld b,a
        ld de,FANFARE_BYTES
.bank:  ld (BANK_P2),a
        ld hl,08000h
.byte:  call fanfare_ready
        ret c
        ld a,(hl)
        out (07Fh),a
        inc hl
        dec de
        ld a,d
        or e
        ret z
        bit 6,h                 ; crossed BFFFh
        jr z,.byte
        inc b
        ld a,b
        jr .bank
.address:
        db 07Eh,2,011h          ; WT header bank 4, external memory access
        db 07Eh,3,020h,07Eh,4,0,07Eh,5,0   ; RAM address 200000h

; The stream contains 500 ticks at 50 Hz. V9990 B1 is set to 60 Hz, so
; five music ticks consume six vertical blanks. AF' holds this countdown.
fanfare_play:
        ld d,0F8h
        call fanfare_read
        ret c
        ld e,a                  ; FM mixer on entry
        inc d
        call fanfare_read
        ret c
        ld d,a                  ; PCM mixer on entry
        push de
        ld a,BANK_FANFARE_MUSIC
        ld (BANK_P2),a
        ld hl,08003h            ; skip the unused three-byte loop pointer
        ld a,5
        ex af,af'
.next:  ld a,(hl)
        inc hl
        cp 0FFh
        jr z,.stop
        cp 0FEh
        jr z,.idle
        ld b,a
        call fanfare_group
        jr c,.stop
        call fanfare_tick
        jr .next
.idle:  ld b,(hl)
        inc hl
.wait:  call fanfare_tick
        djnz .wait
        jr .next
.stop:  pop hl                  ; L = saved FM mixer, H = saved PCM mixer
        ld c,07Eh
        ld d,068h
        ld e,040h               ; key off and damp all 24 PCM slots
        ld b,24
.off:   call fanfare_write
        ret c
        inc d
        djnz .off
        ld d,0F8h
        ld e,l
        call fanfare_write
        ret c
        inc d
        ld e,h
        call fanfare_write
        ret c
        ld a,1
        ld (pcm_ready),a        ; the cover will reuse the logo samples' RAM
        ret

fanfare_tick:
        call v9_wait_frame
        ex af,af'
        dec a
        jr nz,.keep
        call v9_wait_frame
        ld a,5
.keep:  ex af,af'
        ret

; D = high byte of the OPL4 SRAM address, low 16 bits zero.
pcm_address:
        ld e,d
        ld c,07Eh
        ld d,3
        call fanfare_write
        ret c
        inc d
        ld e,0
        call fanfare_write
        ret c
        inc d
        jp fanfare_write

pcm_prepare:
        ld c,07Eh
        ld de,00211h            ; wave headers at 200000h, SRAM access enabled
        call fanfare_write
        ret c
        ld d,020h
        call pcm_address
        ret c
        ld de,0065Ah
        call fanfare_write
        ret c
        ld d,024h               ; 128/256 KiB SRAM may be mirrored or absent here
        call pcm_address
        ret c
        ld de,006A5h
        call fanfare_write
        ret c
        ld d,024h
        call pcm_address
        ret c
        ld d,6
        call fanfare_read
        ret c
        cp 0A5h
        jr nz,.small
        ld d,020h
        call pcm_address
        ret c
        ld d,6
        call fanfare_read
        ret c
        cp 05Ah
        jr nz,.small
        ld ix,pcm_large
        ld b,1
        jr .upload
.small: ld ix,pcm_small
        ld b,2
.upload:
        push bc
        ld d,020h
        call pcm_address
        jr c,.end
        ld a,6
        out (07Eh),a
.chunk: ld a,(ix+0)
        cp 0FFh
        jr z,.verify
        ld (BANK_P2),a
        ld l,(ix+1)
        ld h,(ix+2)
        ld e,(ix+3)
        ld d,(ix+4)
        ld bc,5
        add ix,bc
.byte:  in a,(0C4h)
        and 3
        jr z,.ready
        call fanfare_ready      ; bounded if the chip stays busy
        jr c,.end
.ready: ld a,(hl)
        out (07Fh),a
        inc hl
        ld a,l
        or a
        call z,opening_poll     ; sample keyboard/joystick every 256 bytes
        dec de
        ld a,d
        or e
        jr nz,.byte
        jr .chunk
.verify:
        ld d,020h
        call pcm_address
        jr c,.end
        ld d,6
        call fanfare_read
        jr c,.end
        cp 053h                 ; marker in the unused wave 384 header
        jr nz,.end
        ld de,00210h            ; keep the header bank, disable external memory writes
        call fanfare_write
        jr c,.end
        ld de,0F82Dh            ; both FM outputs -15 dB, PCM at its normal level
        call fanfare_write
        jr c,.end
        pop bc
        ld a,b
        ld (pcm_ready),a
        ret
.end:   pop bc
        ret

        include "../build/port/pcm_chunks.inc"
