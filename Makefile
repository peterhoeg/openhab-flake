ARGS ?= --keep-going --no-keep-outputs --print-out-paths
BUILD = @nix build .\#openhab$(1) .\#openhab$(1)-addons $(ARGS)

default: all

all: openhab3 openhab4

openhab3:
	$(call BUILD,34)

openhab4:
	$(call BUILD,40)
