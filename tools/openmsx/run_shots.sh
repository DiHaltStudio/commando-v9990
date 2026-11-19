#!/bin/sh
# usage: SH_TIMES="t t ..." [SH_KEYS="t:row:mask:dur ..."] [SH_POKES="t:addr:val ..."] tools/openmsx/run_shots.sh ROM OUTDIR ENDSECS
# openMSX offscreen by default. Set TEST_DISPLAY to use an existing X display.
set -e
ROM=$(realpath -- "$1")
mkdir -p "$2"
DIR=$(realpath -- "$2")
SCRIPT=$(realpath -- "$(dirname -- "$0")/shots.tcl")
SH_END=$3
export SH_END
shift 3
rm -f "$DIR"/shot*.png "$DIR"/log.txt
if [ -n "${TEST_DISPLAY:-}" ]; then
    export DISPLAY="$TEST_DISPLAY"
else
    export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-offscreen}"
fi
OPENMSX_USER_DATA=$HOME/.cache/openmsx-tests/share SH_DIR=$DIR SH_TIMES=${SH_TIMES-15 28} \
    timeout 600 "${OPENMSX:-openmsx}" \
    -machine "${MACHINE:-Panasonic_FS-A1GT}" -ext gfx9000 "$@" -cart "$ROM" -romtype ASCII16 -script "$SCRIPT" >"$DIR/openmsx.log" 2>&1
ls "$DIR"
