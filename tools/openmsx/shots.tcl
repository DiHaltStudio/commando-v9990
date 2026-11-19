# Timed screenshots, key presses and pokes. Environment:
#   SH_DIR    output directory
#   SH_TIMES  space-separated emulated times for screenshots (seconds)
#   SH_KEYS   space-separated "time:row:mask:duration" key presses (MSX keyboard matrix)
#   SH_POKES  space-separated "time:addr:value" memory writes
#   SH_END    quit time
# log.txt gets, every second, the PC, the arcade game state and the runtime counters.
set throttle off
set save_settings_on_exit false
catch { set gamma 1.0 }          ;# the palette as written (the default 1.1 lightens the screenshots)
catch { set mute on }
# Raw screenshots read the main window's video layer.
catch { set v9990windows false }
after time 1 { catch { set videosource GFX9000 } }
set ::sh_n 0
proc shot {} {
    incr ::sh_n
    screenshot -raw [format "%s/shot%02d.png" $::env(SH_DIR) $::sh_n]
}
foreach t $::env(SH_TIMES) { after time $t shot }
if {[info exists ::env(SH_KEYS)]} {
    foreach k $::env(SH_KEYS) {
        lassign [split $k :] t row mask dur
        after time $t "keymatrixdown $row $mask"
        after time [expr {$t + $dur}] "keymatrixup $row $mask"
    }
}
if {[info exists ::env(SH_POKES)]} {
    foreach k $::env(SH_POKES) {
        lassign [split $k :] t addr val
        after time $t "poke $addr $val"
    }
}
set ::f [open "$::env(SH_DIR)/log.txt" w]
proc log {} {
    puts $::f "t=[format %.1f [machine_info time]] pc=[format %04X [reg pc]] state=[peek 0xE000] sub=[peek 0xE001] frame=[peek 0xE002] pos=[format %02X%02X [peek 0xE05B] [peek 0xE05C]] set=[peek 0xC014] miss=[peek16 0xC01C] fb=[peek16 0xC01E] unk=[peek16 0xC020] tick=[peek 0xC012] build=[peek 0xC030] used=[peek 0xC899] last=[peek 0xC898] debt=[peek 0xC02A] fkey=[format %04X [peek16 0xC02C]] bkey=[format %04X [peek16 0xC02E]] credits=[peek 0xE030] p1=[format %02X [peek 0xC001]]"
    flush $::f
    after time 1 log
}
after time 1 log
after time $::env(SH_END) { close $::f; exit }
