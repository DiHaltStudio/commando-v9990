; =============================================================================
; Commando for MSX1 + V9990: sound driver (SOUND bank, mapped on page 1).
;
; A port of the arcade's sound CPU program (cm02.9f, see
; see docs/DESIGN.md): the same sequencer logic, the same data (the
; sound ROM itself follows this code in the bank: patches, effect scripts
; and musics at their original offsets, so every pointer is the ROM address
; | $4000), but the output goes to an OPL3 (MoonSound FM part, ports
; $C4-$C7, six 4-operator channels) instead of the two YM2203 FM parts and
; the two SSGs are rendered to wavetable effects on MoonSound. The MSX PSG
; handles effects on other machines. The command, patch and note tables come from
; tools/gen_sound.py (build/port/sound_tabs.inc, included by the overlay,
; which is mapped on page 2 while the driver runs).
;
; The arcade sound CPU ticks at 240 Hz; the interrupt handler calls
; snd_frame at every vertical interrupt: 4 ticks, then the PSG registers.
; The command latch and the control port (b4 = sound CPU reset) are the
; arcade's output shadows in page 3.
; =============================================================================
        include "common.inc"

; ---- RAM (an unused region of the arcade work RAM, cleared by its reset)
SND_RAM         equ 0EA00h
snd_grp         equ SND_RAM             ; 4 music groups x 6 FM channels x 16 bytes
snd_slot        equ SND_RAM+384         ; 8 effect slots x 32 bytes (chip 1 slots 0-3, chip 2 slots 4-7)
snd_regs        equ SND_RAM+640         ; 4 x 16: SSG register images (regs 0-10) of chip 1, chip 2, merged, last written
snd_tick        equ SND_RAM+704
snd_last        equ SND_RAM+705         ; last latch value seen
snd_opl         equ SND_RAM+706         ; OPL3 present
snd_held        equ SND_RAM+707         ; the sound CPU is held in reset (silenced)
snd_b0          equ SND_RAM+708         ; 6: last $B0 value of each FM channel (key-off keeps block / F-number)
snd_cur         equ SND_RAM+714         ; 2: scratch
snd_psg_on      equ SND_RAM+716         ; the PSG carries an effect (else it was silenced)
pcm_last        equ SND_RAM+719         ; active PCM slot per arcade chip ($FF = none)
snd_note_tab    equ SND_RAM+717         ; 2: FM frequency table selected during chip detection

; FM channel record (IX)
F_ON            equ 0
F_CH            equ 1                   ; channel 0-5
F_LEN           equ 2                   ; 2: ticks left in the event
F_GATE          equ 4
F_GCNT          equ 5                   ; 2: ticks until the key-off
F_PTR           equ 7                   ; 2
F_LPTR          equ 9                   ; 2
F_LCNT          equ 11
F_INS           equ 12
F_TAB           equ 13                  ; transpose: frequency table entry of pitch 0
F_TEMPO         equ 14
F_TIE           equ 15                  ; tie counter (b0-4), triplet (b7)

; SSG slot record (IX)
S_ON            equ 0
S_PER           equ 1                   ; 3 x 2: tone period x 16 (A, B, C)
S_NOISE         equ 7                   ; noise period x 8
S_MIX           equ 8
S_VOL           equ 9                   ; 3: volume x 16
S_TSL           equ 12                  ; 3: tone slide per tick
S_VSL           equ 15                  ; 3: volume slide per 4 ticks
S_NSL           equ 18                  ; noise slide per 4 ticks
S_WAIT          equ 19                  ; 2
S_PTR           equ 21                  ; 2
S_LPTR          equ 23                  ; 2
S_LCNT          equ 25
S_CUR           equ 26
S_NXT           equ 27

OPL_A0          equ 0C4h                ; OPL3 bank 0 address / data, bank 1 address / data
OPL_D0          equ 0C5h
OPL_A1          equ 0C6h
OPL_D1          equ 0C7h
PSG_A           equ 0A0h
PSG_D           equ 0A1h

        org 04000h
        jp snd_frame            ; $4000: a frame (4 ticks + PSG), from the interrupt handler

; =============================================================================
; Frame: the arcade holds the sound CPU in reset with b4 of its control port
; (at power-on and in the test mode); released, the sound CPU starts clean.
; =============================================================================
snd_frame:
        ld a,(paused)           ; the pause: the chips silenced once, the sequencer stopped
        or a
        jr z,.run
        ld a,(snd_paused)
        or a
        ret nz
        inc a
        ld (snd_paused),a
        jp snd_silence
.run:   ld (snd_paused),a
        ld a,(IO_CONTROL)
        bit 4,a
        jr nz,.held
        ld a,(snd_held)
        or a
        call nz,snd_init        ; just released: reset
        ld hl,snd_tick          ; 4 ticks per frame (the counter stays a multiple of 4 at
        ld a,(hl)               ; the frame boundary: sub-tick i of the frame is tick + i)
        add a,4
        ld (hl),a
        ld a,(IO_SOUNDLATCH)    ; the arcade latches one command per frame: one poll
        ld hl,snd_last
        cp (hl)
        jr z,.nocmd
        ld (hl),a
        inc a
        jr z,.nocmd             ; $FF: no command
        dec a
        and 03Fh
        cp 02Fh
        jr nc,.nocmd            ; (the arcade would execute data)
        call snd_command
.nocmd: call fm_frame
        ld a,(pcm_ready)
        or a
        jp nz,pcm_frame
        call ssg_frame
        jp psg_write
.held:  ld a,(snd_held)
        or a
        ret nz
        ld a,1
        ld (snd_held),a
        jp snd_silence

; reset: state cleared, chips silent, OPL3 configured (4-op mode)
snd_init:
        xor a
        ld (snd_held),a
        ld hl,SND_RAM
        ld de,SND_RAM+1
        ld bc,snd_psg_on+1-SND_RAM-1
        ld (hl),a
        ldir
        ld a,0FFh
        ld (snd_last),a
        ld c,OPL_A0             ; OPL3 detection: timer 1 must raise its flag in the status port
        ld a,4
        ld e,060h
        call opl_write          ; timers masked
        ld a,4
        ld e,080h
        call opl_write          ; flags reset
        in a,(OPL_A0)
        and 0E0h
        jr nz,.noopl            ; flags set with the timers off: not an OPL3
        ld a,2
        ld e,0FFh
        call opl_write          ; timer 1 = 1 tick (80 us)
        ld a,4
        ld e,021h
        call opl_write          ; timer 1 on, timer 2 masked
        ld b,80
.wait:  ex (sp),hl
        ex (sp),hl
        djnz .wait              ; ~0.9 ms
        in a,(OPL_A0)
        and 0C0h
        cp 0C0h
        push af
        ld a,4
        ld e,060h
        call opl_write
        ld a,4
        ld e,080h
        call opl_write          ; timers off, flags reset
        pop af
        jr nz,.noopl
        ld a,1
        ld (snd_opl),a
        ld c,OPL_A1
        ld a,5
        ld e,3
        call opl_write          ; NEW and NEW2: allow selecting the OPL4 wave ID
        ld a,2
        out (07Eh),a
        ex (sp),hl              ; allow the YMF278B wave register select to settle
        ex (sp),hl
        in a,(07Fh)
        and 0E0h                ; wave register 2, bits 7-5: device ID
        cp 020h
        ld hl,opl_note_tab
        jr nz,.clock
        ld hl,opl4_note_tab
.clock: ld (snd_note_tab),hl
        ld e,1
        ld a,(pcm_ready)
        or a
        jr z,.mode
        ld e,3                  ; enable the wave registers alongside FM
.mode:  ld a,5
        call opl_write
        ld a,4
        ld e,03Fh
        call opl_write          ; six 4-op channels
        ld c,OPL_A0
        ld a,1
        ld e,0
        call opl_write
        ld a,8
        call opl_write
        ld a,0BDh
        call opl_write
.noopl: jp snd_silence

; every FM channel keyed off, the PSG quiet
snd_silence:
        ld a,(pcm_ready)
        or a
        call nz,pcm_silence
        call snd_silence_fm
        ld a,7
        out (PSG_A),a
        ld a,0BFh
        out (PSG_D),a
        ld a,8
        out (PSG_A),a
        xor a
        out (PSG_D),a
        ld a,9
        out (PSG_A),a
        xor a
        out (PSG_D),a
        ld a,10
        out (PSG_A),a
        xor a
        out (PSG_D),a
        ret

; A = command 0-$2E
snd_command:
        ld b,a
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,snd_cmd_tab
        add hl,de
        ld a,(hl)               ; type
        inc hl
        ld c,(hl)               ; parameter
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)               ; pointer
        or a
        jr z,.stop_sfx
        dec a
        jr z,.sfx
        dec a
        jr z,.music
        ; stop the music: channel 0 of every group off, channels keyed off
        ld hl,snd_grp
        ld bc,6*16
        ld (hl),0
        add hl,bc
        ld (hl),0
        add hl,bc
        ld (hl),0
        add hl,bc
        ld (hl),0
        jp snd_silence_fm
.stop_sfx:
        ld hl,snd_slot
        ld de,32
        ld b,8
.s:     ld (hl),0
        add hl,de
        djnz .s
        ret
.sfx:   ld a,c                  ; slot C: script DE
        rrca
        rrca
        rrca                    ; x 32
        ld l,a
        ld h,0
        push de
        ld de,snd_slot
        add hl,de
        pop de
        push hl
        pop ix
        ld a,(pcm_ready)
        or a
        jp nz,pcm_start
        ld (ix+S_PTR),e
        ld (ix+S_PTR+1),d
        ld (ix+S_LPTR),e
        ld (ix+S_LPTR+1),d
        xor a
        ld (ix+S_WAIT),a
        ld (ix+S_WAIT+1),a
        ld (ix+S_LCNT),a
        ld (ix+S_MIX),0FFh
        dec (ix+S_ON)           ; 0 -> $FF
        ret
.music: ld l,c                  ; group C: header DE
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; x 32
        push de
        ld e,l
        ld d,h
        add hl,hl               ; x 64
        add hl,de               ; x 96
        ld de,snd_grp
        add hl,de
        pop de
        ; fall through
; start the music whose header is at DE in the group at HL
mus_start:
        ld a,(de)
        ld (snd_cur),a          ; tempo
        push hl
        pop ix
        ld b,6
        ld c,0                  ; channel
        inc de
.ch:    push bc
        xor a
        ld (ix+F_ON),a
        ld (ix+F_LEN),a
        ld (ix+F_LEN+1),a
        ld (ix+F_TIE),a
        ld (ix+F_CH),c
        ld a,(de)
        inc de
        ld (ix+F_PTR),a
        ld a,(de)
        inc de
        or 040h
        ld (ix+F_PTR+1),a
        ld a,(de)
        inc de
        ld (ix+F_INS),a
        ld a,(de)
        inc de
        ld (ix+F_GATE),a
        ld a,(snd_cur)
        ld (ix+F_TEMPO),a
        dec (ix+F_ON)           ; $FF
        push de
        call load_patch
        pop de
        ld bc,16
        add ix,bc
        pop bc
        inc c
        djnz .ch
        ret

; the patch of the channel IX -> its OPL3 operators (18 register writes)
load_patch:
        ld a,(snd_opl)
        or a
        ret z
        ld a,(ix+F_INS)
        ld l,a
        ld h,0
        add hl,hl               ; x 18 = x 16 + x 2
        ld e,l
        ld d,h
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,de
        ld de,opl_patch_tab
        add hl,de
        ld a,(ix+F_CH)
        call opl_chan           ; C = address port, A = channel 0-2 in the bank
        ld b,a                  ; B = channel
        ld d,a                  ; operator offsets: ch, ch+3, ch+8, ch+11
        call .op
        ld a,d
        add a,3
        call .op
        ld a,d
        add a,8
        call .op
        ld a,d
        add a,11
        call .op
        ld a,b
        add a,0C0h
        ld e,(hl)
        inc hl
        call opl_write          ; channel A: feedback, connection, L + R
        ld a,b
        add a,0C3h
        ld e,(hl)
        jp opl_write            ; channel B
.op:    add a,020h
        ld e,(hl)
        inc hl
        call opl_write
        add a,020h
        ld e,(hl)
        inc hl
        call opl_write
        add a,020h
        ld e,(hl)
        inc hl
        call opl_write
        add a,020h
        ld e,(hl)
        inc hl
        jp opl_write

; A = channel 0-5 -> C = OPL3 address port of its bank, A = channel in the bank
opl_chan:
        ld c,OPL_A0
        cp 3
        ret c
        ld c,OPL_A1
        sub 3
        ret

; OPL3 register A := E through the port pair at C (address port). Keeps A, B, DE, HL.
opl_write:
        out (c),a
        ex (sp),hl
        ex (sp),hl
        inc c
        out (c),e
        dec c
        ex (sp),hl
        ex (sp),hl
        ret

; $B0 of channel A (0-5) := E (key on / off with the block and F-number)
opl_b0:
        push bc
        call opl_chan
        add a,0B0h
        call opl_write
        pop bc
        ret

; every FM channel keyed off
snd_silence_fm:
        ld a,(snd_opl)
        or a
        ret z
        ld b,6
        ld hl,snd_b0
.k:     ld a,(hl)
        and 0DFh
        ld (hl),a
        ld e,a
        ld a,6
        sub b
        push bc
        push hl
        call opl_b0
        pop hl
        pop bc
        inc hl
        djnz .k
        ret

; =============================================================================
; Music sequencer, 4 ticks: the highest group whose channel 0 is active.
; A channel in the middle of a long event takes the 4 ticks at once (length
; and gate counters - 4); otherwise it is stepped tick by tick (the triplet
; pacing uses the tick parity).
; =============================================================================
fm_frame:
        ld ix,snd_grp+3*96
        ld a,(snd_grp+3*96)
        or a
        jr nz,.run
        ld ix,snd_grp+2*96
        ld a,(snd_grp+2*96)
        or a
        jr nz,.run
        ld ix,snd_grp+96
        ld a,(snd_grp+96)
        or a
        jr nz,.run
        ld ix,snd_grp
        ld a,(snd_grp)
        or a
        ret z
.run:   ld b,6
.c:     push bc
        ld a,(ix+F_ON)
        or a
        jp z,.n
        bit 7,(ix+F_TIE)
        jr nz,.slow             ; triplet
        ld a,(ix+F_LEN+1)
        or a
        jr nz,.long
        ld a,(ix+F_LEN)
        cp 6
        jr c,.slow              ; the event ends within the frame
.long:  ld a,(ix+F_TIE)
        and 01Fh
        jr nz,.len4             ; tied: no gate
        ld l,(ix+F_GCNT)
        ld h,(ix+F_GCNT+1)
        ld a,l
        or h
        jr z,.len4              ; no key-off pending
        ld a,h
        or a
        jr nz,.gate4
        ld a,l
        cp 5
        jr c,.slow              ; the key-off falls within the frame
.gate4: ld a,l
        sub 4
        ld (ix+F_GCNT),a
        jr nc,.len4
        dec (ix+F_GCNT+1)
.len4:  ld a,(ix+F_LEN)
        sub 4
        ld (ix+F_LEN),a
        jr nc,.n
        dec (ix+F_LEN+1)
        jr .n
.slow:  ld c,4                  ; C = 4..1: sub-tick i = 5 - C (the counter at sub-tick i is
        ld l,(ix+F_LEN)         ; tick - 4 + i: odd when i is odd, i.e. when C is even)
        ld h,(ix+F_LEN+1)
        ld e,(ix+F_GCNT)
        ld d,(ix+F_GCNT+1)      ; HL = length, DE = gate counter, in registers for the 4 ticks
.t:     ld a,(ix+F_ON)
        or a
        jr z,.n
        bit 7,(ix+F_TIE)
        jr z,.one
        ld a,c
        rrca
        jr c,.one
        call .step              ; a triplet steps twice on odd ticks
.one:   call .step
        dec c
        jr nz,.t
        ld (ix+F_LEN),l
        ld (ix+F_LEN+1),h
        ld (ix+F_GCNT),e
        ld (ix+F_GCNT+1),d
        jr .n
.step:  ld a,h                  ; one tick: HL = length, DE = gate counter
        or a
        jr nz,.dec
        ld a,l
        cp 2
        jr c,.ev                ; length 0 or 1: the next event
.dec:   dec hl
        ld a,(ix+F_TIE)
        and 01Fh
        ret nz                  ; tied: no gate
        ld a,d
        or e
        ret z
        dec de
        ld a,d
        or e
        ret nz
        push hl                 ; key-off
        push de
        push bc
        call fm_keyoff
        pop bc
        pop de
        pop hl
        ret
.ev:    push bc
        call fm_event
        pop bc
        ld l,(ix+F_LEN)
        ld h,(ix+F_LEN+1)
        ld e,(ix+F_GCNT)
        ld d,(ix+F_GCNT+1)
        ret
.n:     ld bc,16
        add ix,bc
        pop bc
        dec b
        jp nz,.c
        ret

; key-off of the channel IX
fm_keyoff:
        ld a,(snd_opl)
        or a
        ret z
        ld a,(ix+F_CH)
        ld hl,snd_b0
        add a,l
        ld l,a
        ld a,(hl)
        and 0DFh
        ld (hl),a
        ld e,a
        ld a,(ix+F_CH)
        jp opl_b0

; the next event of the channel IX (sets its length and gate counters)
fm_event:
        res 7,(ix+F_TIE)        ; triplet off
.loop:  call fetch
        ld b,a
        and 01Fh
        jr z,.rest
        cp 01Fh
        jr z,.control
        ld a,b
        cp 020h
        jr c,.instrument
        cp 040h
        jr c,.prefix
        ; a note
        ld a,(ix+F_TIE)
        and 01Fh
        jr z,.key
        dec (ix+F_TIE)
.key:   ld a,b
        call key_on
        ld a,b
        jp set_length
.rest:  ld a,b                  ; the gate of the previous note does the key-off
        jp set_length
.instrument:
        ld (ix+F_INS),a
        call fetch
        ld (ix+F_GATE),a
        call load_patch
        jr .loop
.prefix:
        cp 030h
        jr nz,.tie
        set 7,(ix+F_TIE)        ; triplet
        jr .loop
.tie:   inc a
        and 01Fh
        ld c,a
        ld a,(ix+F_TIE)
        and 080h
        or c
        ld (ix+F_TIE),a
        jr .loop
.control:
        ld a,b
        rlca
        rlca
        rlca
        and 7
        jr z,.transpose
        dec a
        jr z,.tempo
        dec a
        jr z,.skip1
        dec a
        jr z,.jump
        dec a
        jr z,.lstart
        dec a
        jr z,.lend
        dec a
        jr z,.dotted
        ld (ix+F_ON),0          ; end of the channel
        ret
.transpose:
        call fetch
        ld (ix+F_TAB),a
        jr .loop
.tempo: call fetch
        ld (ix+F_TEMPO),a
        jp .loop
.skip1: call fetch
        jp .loop
.jump:  call fetch
        ld c,a
        call fetch
        or 040h
        ld (ix+F_PTR),c
        ld (ix+F_PTR+1),a
        jp .loop
.lstart:
        ld a,(ix+F_PTR)
        ld (ix+F_LPTR),a
        ld a,(ix+F_PTR+1)
        ld (ix+F_LPTR+1),a
        ld (ix+F_LCNT),0
        jp .loop
.lend:  call fetch
        inc (ix+F_LCNT)
        cp (ix+F_LCNT)
        jp c,.loop              ; n < count: done
        ld a,(ix+F_LPTR)
        ld (ix+F_PTR),a
        ld a,(ix+F_LPTR+1)
        ld (ix+F_PTR+1),a
        jp .loop
.dotted:
        call fetch
        ld b,a
        and 01Fh
        jr z,.drest
        ld a,b
        call key_on
.drest: ld a,b
        jp set_length_dotted

; A = the next sequence byte of the channel IX
fetch:
        ld l,(ix+F_PTR)
        ld h,(ix+F_PTR+1)
        ld a,(hl)
        inc hl
        ld (ix+F_PTR),l
        ld (ix+F_PTR+1),h
        ret

; key on: A = note byte (pitch in b0-4) of the channel IX
key_on:
        and 01Fh
        add a,(ix+F_TAB)        ; frequency table entry
        ld l,a
        ld h,0
        add hl,hl
        ld de,(snd_note_tab)
        add hl,de
        ld a,(snd_opl)
        or a
        ret z
        push bc
        ld e,(hl)               ; $A0 value
        inc hl
        ld d,(hl)               ; $B0 value
        set 5,d                 ; key on
        ld a,(ix+F_CH)
        ld hl,snd_b0
        add a,l
        ld l,a
        ld (hl),d
        ld a,(ix+F_CH)
        call opl_chan           ; C = address port, A = channel in the bank
        ld b,a
        add a,0A0h
        call opl_write          ; F-number low
        ld e,d
        ld a,b
        add a,0B0h
        call opl_write          ; key on, block, F-number high
        pop bc
        ret

; length and gate of the event: A = its byte (length index in b5-7), IX = channel
set_length_dotted:
        ld hl,tab_len_dotted
        jr set_length_tab
set_length:
        ld hl,tab_len_normal
set_length_tab:
        rlca
        rlca
        rlca
        and 7
        add a,l
        ld l,a
        jr nc,.tab
        inc h
.tab:   ld a,(hl)               ; length units
        ld e,(ix+F_TEMPO)
        ld d,0
        ld hl,0
        ld b,8
.mul:   add hl,hl
        rlca
        jr nc,.m0
        add hl,de
.m0:    djnz .mul               ; HL = units x tempo
        ld (ix+F_LEN),l
        ld (ix+F_LEN+1),h
        ld a,(ix+F_GATE)
        and 15
        jr nz,.g
        inc a
.g:     inc a                   ; g + 1 (2-16)
        rlca
        rlca
        rlca                    ; its 5 bits at b7-3
        ld e,l
        ld d,h
        ld hl,0
        ld b,5
.mul2:  add hl,hl
        rlca
        jr nc,.n0
        add hl,de
.n0:    djnz .mul2              ; HL = len x (g + 1)
        ld a,l                  ; >> 4
        rrca
        rrca
        rrca
        rrca
        and 0Fh
        ld c,a
        ld a,h
        rlca
        rlca
        rlca
        rlca
        and 0F0h
        or c
        ld (ix+F_GCNT),a
        ld a,h
        rrca
        rrca
        rrca
        rrca
        and 0Fh
        ld (ix+F_GCNT+1),a
        ret

tab_len_normal:
        db 0,0,2,4,8,16,32,64
tab_len_dotted:
        db 0,0,3,6,12,24,48,96

; =============================================================================
; Effects, 4 ticks: the highest active slot of each chip runs its script. A
; slot waiting 4 ticks or more takes them at once (the tone slides x 4, the
; volume and noise slides once: they run every 4th tick); otherwise tick by
; tick.
; =============================================================================
ssg_frame:
        ld ix,snd_slot+3*32     ; chip 1: the highest active slot
        ld a,(snd_slot+3*32)
        or a
        jr nz,.r1
        ld ix,snd_slot+2*32
        ld a,(snd_slot+2*32)
        or a
        jr nz,.r1
        ld ix,snd_slot+32
        ld a,(snd_slot+32)
        or a
        jr nz,.r1
        ld ix,snd_slot
        ld a,(snd_slot)
        or a
        jr z,.c2
.r1:    call slot_frame
.c2:    ld ix,snd_slot+7*32     ; chip 2
        ld a,(snd_slot+7*32)
        or a
        jr nz,.r2
        ld ix,snd_slot+6*32
        ld a,(snd_slot+6*32)
        or a
        jr nz,.r2
        ld ix,snd_slot+5*32
        ld a,(snd_slot+5*32)
        or a
        jr nz,.r2
        ld ix,snd_slot+4*32
        ld a,(snd_slot+4*32)
        or a
        ret z
.r2:    jp slot_frame

; the 4 ticks of the slot IX
slot_frame:
        ld l,(ix+S_WAIT)
        ld h,(ix+S_WAIT+1)
        ld a,h
        or a
        jr nz,.fast
        ld a,l
        cp 4
        jr c,.slow
.fast:  ld de,-4
        add hl,de
        ld (ix+S_WAIT),l
        ld (ix+S_WAIT+1),h
        ld c,4
        jp slides               ; tones x 4, volumes and noise once
.slow:  ld c,1                  ; sub-ticks 1-4
.t:     ld a,(ix+S_ON)
        or a
        ret z
        push bc
        call ssg_tick
        pop bc
        inc c
        ld a,c
        cp 5
        jr c,.t
        ret

; one tick of the slot IX (C = sub-tick 1-4: the volume slides run on the 4th)
ssg_tick:
        ld l,(ix+S_WAIT)
        ld h,(ix+S_WAIT+1)
        ld a,l
        or h
        jr z,ssg_run
        dec hl
        ld (ix+S_WAIT),l
        ld (ix+S_WAIT+1),h
        ld a,c
        cp 4
        ld c,1                  ; tones x 1
        jp z,slides
        jp slides_tone

ssg_run:
.flow:  call sfetch
        ld b,a
        rrca
        rrca
        and 7
        jr z,.wait
        dec a
        jr z,.lstart
        dec a
        jr z,.lend
        dec a
        jr z,.jump
        ld (ix+S_ON),0          ; end
        ret
.wait:  ld a,b
        and 3
        ld (ix+S_WAIT+1),a
        call sfetch
        ld (ix+S_WAIT),a
        jr .regs
.lstart:
        ld a,(ix+S_PTR)
        ld (ix+S_LPTR),a
        ld a,(ix+S_PTR+1)
        ld (ix+S_LPTR+1),a
        ld (ix+S_LCNT),0
        jr .flow
.lend:  call sfetch
        inc (ix+S_LCNT)
        cp (ix+S_LCNT)
        jr z,.flow
        ld a,(ix+S_LPTR)
        ld (ix+S_PTR),a
        ld a,(ix+S_LPTR+1)
        ld (ix+S_PTR+1),a
        jr .flow
.jump:  call sfetch
        ld c,a
        call sfetch
        or 040h
        ld (ix+S_PTR),c
        ld (ix+S_PTR+1),a
        jr .flow
        ; register commands until the next flow code
.regs:  ld a,(ix+S_NXT)
        and 0E0h
        jp z,.done
        call sfetch
        ld b,a
        rlca
        rlca
        rlca
        and 7                   ; 1-3 tone, 4-6 volume, 7 noise
        cp 4
        jr nc,.volnoise
        ; tone n: period (b & 15) << 8 | next; 0 = off, $FFF = unchanged; then the slide
        dec a
        ld c,a                  ; channel 0-2
        ld a,b
        and 15
        ld d,a
        call sfetch
        ld e,a                  ; DE = P
        ld a,d
        or e
        jr nz,.pnz
        ; P = 0: tone off, period 0
        ld a,c
        add a,a
        add a,S_PER
        push ix
        pop hl
        add a,l
        ld l,a
        ld (hl),0
        inc hl
        ld (hl),0
        ld a,c
        call bitmask
        or (ix+S_MIX)
        ld (ix+S_MIX),a
        jr .tslide
.pnz:   ld a,d
        cp 0Fh
        jr nz,.pset
        ld a,e
        inc a
        jr z,.tslide            ; $FFF: unchanged
.pset:  ex de,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; P x 16
        ex de,hl
        ld a,c
        add a,a
        add a,S_PER
        push ix
        pop hl
        add a,l
        ld l,a
        ld (hl),e
        inc hl
        ld (hl),d
        ld a,c
        call bitmask
        cpl
        and (ix+S_MIX)
        ld (ix+S_MIX),a
.tslide:
        call sfetch
        push ix
        pop hl
        ld e,a
        ld a,c
        add a,S_TSL
        add a,l
        ld l,a
        ld (hl),e
        jr .regs
.volnoise:
        cp 7
        jr z,.noise
        sub 4
        ld c,a                  ; channel
        ld a,b
        and 01Fh
        cp 01Fh
        jr z,.vslide
        ld a,b
        rrca
        rrca
        rrca
        rrca
        and 0F0h                ; (b << 4) & $FF
        push ix
        pop hl
        ld e,a
        ld a,c
        add a,S_VOL
        add a,l
        ld l,a
        ld (hl),e
.vslide:
        call sfetch
        push ix
        pop hl
        ld e,a
        ld a,c
        add a,S_VSL
        add a,l
        ld l,a
        ld (hl),e
        jp .regs
.noise: ld a,b
        and 01Fh
        cp 01Fh
        jr z,.nmix
        ld a,b
        rlca
        rlca
        rlca
        and 0F8h                ; (b << 3) & $FF
        ld (ix+S_NOISE),a
.nmix:  call sfetch
        and 038h
        ld c,a
        ld a,(ix+S_MIX)
        and 0C7h
        or c
        ld (ix+S_MIX),a
        call sfetch
        ld (ix+S_NSL),a
        jp .regs
.done:  ld l,(ix+S_WAIT)        ; wait - 1
        ld h,(ix+S_WAIT+1)
        dec hl
        ld (ix+S_WAIT),l
        ld (ix+S_WAIT+1),h
        ret

; A = 1 << A (0-2)
bitmask:
        or a
        ld a,1
        ret z
        ld a,2
        dec a
        ret z
        ld a,4
        ret

; A = the next script byte of the slot IX (also peeks the one after it)
sfetch:
        ld l,(ix+S_PTR)
        ld h,(ix+S_PTR+1)
        ld a,(hl)
        ld (ix+S_CUR),a
        inc hl
        ld (ix+S_PTR),l
        ld (ix+S_PTR+1),h
        ld a,(hl)
        ld (ix+S_NXT),a
        ld a,(ix+S_CUR)
        ret

; the slides of the slot IX: tones every tick (x C ticks here), volumes and
; noise every 4th tick (slides: once; slides_tone: tones only)
slides:
        call slides_tone
        ld b,3
        push ix
        pop hl
        ld d,h
        ld a,l
        add a,S_VOL
        ld l,a
        add a,S_VSL-S_VOL
        ld e,a                  ; DE -> S_VSL (same page: the slot is 32-aligned)
.v:     ld a,(de)
        add a,(hl)
        ld (hl),a
        inc l
        inc e
        djnz .v
        ld a,(ix+S_NSL)
        add a,(ix+S_NOISE)
        ld (ix+S_NOISE),a
        ret
slides_tone:
        push ix
        pop hl
        ld de,S_PER
        add hl,de               ; HL -> period A
        push ix
        pop de
        ld a,e
        add a,S_TSL
        ld e,a                  ; DE -> slide A
        ld b,3
.ch:    push bc
        ld a,(de)
        inc de
        push de
        ld e,a
        rlca
        sbc a,a
        ld d,a                  ; DE = slide (signed 16)
        ld a,c
        cp 4
        jr nz,.x1
        ex de,hl
        add hl,hl
        add hl,hl
        ex de,hl                ; x 4
.x1:    ld a,(hl)
        add a,e
        ld (hl),a
        inc hl
        ld a,(hl)
        adc a,d
        ld (hl),a
        inc hl
        pop de
        pop bc
        djnz .ch
        ret

; =============================================================================
; PSG: the register images of both chips (highest active slot each, else
; silence) merged into the MSX PSG: per tone channel the one of chip 1 when
; it sounds there (tone or noise on), else chip 2's; the noise period of
; the chip that uses noise (chip 1 first). snd_regs: chip 1 image (+0),
; chip 2 image (+16), the merged image (+32).
; =============================================================================
psg_write:
        ld hl,snd_slot          ; any effect slot active? else the PSG stays as it is
        ld de,32
        ld b,8
        xor a
.any:   or (hl)
        add hl,de
        djnz .any
        or a
        jr nz,.build
        ld a,(snd_psg_on)
        or a
        ret z                   ; already silent
        xor a
        ld (snd_psg_on),a
        jr .silent
.build: ld a,1
        ld (snd_psg_on),a
        ld ix,snd_slot+3*32
        ld de,snd_regs
        call .image
        ld ix,snd_slot+7*32
        ld de,snd_regs+16
        call .image
        jr .merge
.silent:
        ld hl,snd_regs+32
        xor a
        ld b,7
.sz:    ld (hl),a
        inc hl
        djnz .sz
        ld (hl),0BFh
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        jp .send
.merge:
        ld d,080h               ; merged mixer (b7: PSG port B output, b6: port A input)
        ; channel A: mask 9 (tone b0, noise b3), period at +0, volume at +8
        ld a,(snd_regs+7)
        and 9
        cp 9
        ld hl,snd_regs
        jr nz,.a
        ld hl,snd_regs+16
.a:     ld a,(hl)
        ld (snd_regs+32),a
        inc l
        ld a,(hl)
        ld (snd_regs+33),a
        ld a,l
        add a,7
        ld l,a
        ld a,(hl)               ; volume
        ld (snd_regs+40),a
        dec l
        ld a,(hl)               ; that chip's mixer
        and 9
        or d
        ld d,a
        ; channel B: mask 18, +2, +9
        ld a,(snd_regs+7)
        and 18
        cp 18
        ld hl,snd_regs+2
        jr nz,.b
        ld hl,snd_regs+16+2
.b:     ld a,(hl)
        ld (snd_regs+34),a
        inc l
        ld a,(hl)
        ld (snd_regs+35),a
        ld a,l
        add a,6
        ld l,a
        ld a,(hl)
        ld (snd_regs+41),a
        dec l
        dec l
        ld a,(hl)
        and 18
        or d
        ld d,a
        ; channel C: mask 36, +4, +10
        ld a,(snd_regs+7)
        and 36
        cp 36
        ld hl,snd_regs+4
        jr nz,.c
        ld hl,snd_regs+16+4
.c:     ld a,(hl)
        ld (snd_regs+36),a
        inc l
        ld a,(hl)
        ld (snd_regs+37),a
        ld a,l
        add a,5
        ld l,a
        ld a,(hl)
        ld (snd_regs+42),a
        dec l
        dec l
        dec l
        ld a,(hl)
        and 36
        or d
        ld (snd_regs+39),a      ; mixer
        ; noise period: chip 1's if it uses noise, else chip 2's
        ld a,(snd_regs+7)
        and 038h
        cp 038h
        ld a,(snd_regs+6)
        jr nz,.np
        ld a,(snd_regs+16+6)
.np:    ld (snd_regs+38),a
        ld hl,snd_regs+32       ; unchanged since the last write: nothing to send
        ld de,snd_regs+48
        ld b,11
.cmp:   ld a,(de)
        cp (hl)
        jr nz,.send
        inc l
        inc e
        djnz .cmp
        ret
.send:  ld hl,snd_regs+32
        ld de,snd_regs+48
        xor a
.w:     out (PSG_A),a
        ld c,a
        ld a,(hl)
        out (PSG_D),a
        ld (de),a
        inc hl
        inc de
        ld a,c
        inc a
        cp 11
        jr c,.w
        ret
; the register image at DE of the chip whose top slot is IX (the highest active slot, else silence)
.image: ld b,4
.i:     ld a,(ix+S_ON)
        or a
        jr nz,.found
        push bc
        ld bc,-32
        add ix,bc
        pop bc
        djnz .i
        ex de,hl
        xor a
        ld b,7
.z:     ld (hl),a
        inc hl
        djnz .z
        ld (hl),0FFh            ; mixer: everything off
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        ret
.found: push ix
        pop hl
        inc hl                  ; S_PER
        ld b,3
.p:     ld a,(hl)
        inc hl
        ld c,(hl)
        inc hl
        rrca
        rrca
        rrca
        rrca
        and 0Fh
        push bc
        ld b,a
        ld a,c
        rlca
        rlca
        rlca
        rlca
        and 0F0h
        or b
        pop bc
        ld (de),a               ; period >> 4
        inc de
        ld a,c
        rrca
        rrca
        rrca
        rrca
        and 0Fh
        ld (de),a               ; period >> 12
        inc de
        djnz .p
        ld a,(ix+S_NOISE)
        rrca
        rrca
        rrca
        and 01Fh
        ld (de),a
        inc de
        ld a,(ix+S_MIX)
        ld (de),a
        inc de
        ld b,3
        push ix
        pop hl
        ld a,l
        add a,S_VOL
        ld l,a
.v:     ld a,(hl)
        inc hl
        rrca
        rrca
        rrca
        rrca
        and 0Fh
        ld (de),a
        inc de
        djnz .v
        ret

; The wave engine plays a rendered 240 Hz arcade script per effect. Each
; YM2203 owns four priority slots. Freeze lower-priority waves in place,
; then resume the sample and its frame counter together. The internal PSG
; handles the same scripts directly when no PCM bank was loaded at boot.
pcm_start:                      ; B = arcade command, IX = priority slot
        ld l,b
        ld h,0
        add hl,hl
        ld de,pcm_duration
        add hl,de
        ld a,(hl)
        ld (ix+1),a
        inc hl
        ld d,(hl)
        ld (ix+2),d
        or d
        jr z,.store             ; a stop-slot command has zero duration
        ld a,b
        or 080h                 ; wave 384 + command, and a pending key-on
.store: ld (ix+0),a
        ret

pcm_frame:
        ld ix,snd_slot+3*32
        ld hl,pcm_last
        ld c,3
        call pcm_chip
        ld ix,snd_slot+7*32
        ld hl,pcm_last+1
        ld c,7
pcm_chip:
        ld b,4
        ld de,-32
.find:  ld a,(ix+0)
        or a
        jr nz,.selected
        add ix,de
        dec c
        djnz .find
        ld c,0FFh
.selected:
        ld a,(hl)
        cp c
        jr z,.same
        ld (hl),c
        inc a
        jr z,.switch
        dec a
        push bc
        ld c,a
        call pcm_freeze
        pop bc
.switch:
        ld a,c
        inc a
        ret z
        bit 7,(ix+0)
        jr nz,.start
        call pcm_pitch
        ld d,068h
        ld e,080h
        call pcm_reg            ; unmute the suspended wave
        jr .tick
.same:  ld a,c
        inc a
        ret z
        bit 7,(ix+0)
        jr z,.tick
.start: ld d,068h
        ld e,0
        call pcm_reg            ; key off before loading the next header
        ld a,(pcm_ready)
        cp 2
        ld e,1                  ; wave number bit 8, F-number low
        jr nz,.wave
        ld e,0E5h               ; compact bank: F-number 498 (114 << 1 | 1)
.wave:  ld d,020h
        call pcm_reg
        ld d,008h
        ld e,(ix+0)
        res 7,(ix+0)
        call pcm_reg            ; wave 384 + command
        call pcm_pitch          ; pcm_reg waits for the header load
        ld d,050h
        ld e,1                  ; direct level 0 dB
        call pcm_reg
        ld d,068h
        ld e,080h               ; key on, centre
        call pcm_reg
.tick:  ld l,(ix+1)
        ld h,(ix+2)
        ld a,h
        and l
        inc a
        ret z                   ; looping until the game sends a new command
        dec hl
        ld (ix+1),l
        ld (ix+2),h
        ld a,l
        or h
        ret nz
        ld (ix+0),a
        ret

pcm_pitch:
        ld a,(pcm_ready)
        cp 2
        ld e,0F0h               ; 11025 Hz (22050 Hz at octave zero)
        jr nz,.set
        ld e,0D3h               ; about 4097 Hz
.set:   ld d,038h
        jp pcm_reg

pcm_silence:
        ld hl,0FFFFh
        ld (pcm_last),hl
        ld c,7
.loop:  call pcm_freeze
        dec c
        jp p,.loop
        ret

pcm_freeze:
        ld d,068h
        ld e,088h               ; key stays on, pan 8 silences both outputs
        call pcm_reg
        ld d,038h
        ld e,080h               ; octave -8 stops sample position advancement
pcm_reg:                        ; D = slot register base, C = slot, E = data
        call pcm_wait
        ret nz
        ld a,d
        add a,c
        out (07Eh),a
        call pcm_wait
        ret nz
        ld a,e
        out (07Fh),a
        ret
pcm_wait:
        push bc
        ld b,0
.wait:  in a,(0C4h)
        and 3                   ; YMF278B BUSY and wavetable header load (LD)
        jr z,.ready
        djnz .wait              ; bounded on a missing/misbehaving device
.ready: pop bc
        ret

pcm_duration:
        include "../build/port/pcm_durations.inc"

        include "../build/port/sound_syms.inc"   ; the tables live in the overlay bank (page 2)
snd_end:
