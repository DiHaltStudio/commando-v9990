# Commando for MSX turbo R + V9990
PY          ?= python3
ARCADE_ROMS ?= local/arcade/commando
COVER_ART   ?=
BASE_ROM    ?=
OPENMSX     ?= openmsx
MACHINE     ?= Panasonic_FS-A1GT
SOUND_EXT   ?= -ext moonsound
VERSION     ?= 1.0
ROM          = build/port/commando_v9990.rom
GAME         = release/commando_v9990.rom
MANUAL_LANGS ?= en es

export ARCADE_ROMS COVER_ART BASE_ROM OPENMSX MACHINE TEST_DISPLAY

all: port

port:
	$(PY) tools/prepare_arcade.py "$(ARCADE_ROMS)" build/arcade
	$(PY) tools/build_port.py

run:
	@rom="$(GAME)"; if [ ! -f "$$rom" ]; then rom="$(ROM)"; fi; \
	if [ ! -f "$$rom" ]; then echo "Put the download in $(GAME) or run make port."; exit 1; fi; \
	"$(OPENMSX)" -machine "$(MACHINE)" -ext gfx9000 $(SOUND_EXT) -cart "$$rom" -romtype ASCII16 \
	    -command "after time 1 {set videosource GFX9000}"

run-st shots-st: MACHINE = Panasonic_FS-A1ST
run-st: run
shots-st: shots

shots: port
	sh tools/openmsx/run_shots.sh "$(ROM)" build/shots "$${SH_END:-30}" $(SOUND_EXT)

tmx: port
	$(PY) tools/make_tmx.py build/port/assets build/arcade build/tmx

manual:
	$(PY) tools/manual_images.py docs/manual .
	cd docs/manual && for l in $(MANUAL_LANGS); do \
	    for i in 1 2; do pdflatex -halt-on-error -interaction=nonstopmode -jobname=manual-$$l "\\def\\manlang{$$l}\\input{manual}" || exit 1; done; \
	done

release: port
	mkdir -p release
	cp "$(ROM)" "$(GAME)"
	cp docs/manual/manual-en.pdf release/Commando-V9990-Manual-EN.pdf
	cp docs/manual/manual-es.pdf release/Commando-V9990-Manual-ES.pdf
	cd release && zip -X -q "Commando-V9990-v$(VERSION).zip" \
	    commando_v9990.rom Commando-V9990-Manual-EN.pdf Commando-V9990-Manual-ES.pdf

help:
	@echo 'make port      Build the ASCII16 cartridge from local inputs'
	@echo 'make run       Play the downloaded or locally built ROM in openMSX'
	@echo 'make run-st    Run on the turbo R ST profile'
	@echo 'make shots     Capture screens from a locally built ROM'
	@echo 'make tmx       Export the map and sprite views'
	@echo 'make manual    Rebuild the English and Spanish PDF manuals'
	@echo 'make release   Package the cartridge and manuals'
	@echo 'make clean     Remove the build directory'

clean:
	rm -rf build

.PHONY: all port run run-st shots shots-st tmx manual release help clean
