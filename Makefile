ARGS ?= --keep-going --no-keep-outputs --print-out-paths
BUILD = @nix build .\#openhab$(1) .\#openhab$(1)-addons $(ARGS)

default: all

all: openhab2 openhab3 openhab4

openhab2:
	@nix build .\#openhab2 .\#openhab2-v1-addons .\#openhab2-v2-addons

openhab3:
	$(call BUILD,34)

openhab4:
	$(call BUILD,42)

vm:
	@nix build .#openhab-microvm && ./result/bin/microvm-run
