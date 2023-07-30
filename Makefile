BUILD = @nix build .\#openhab$(1) .\#openhab$(1)-addons

default: all

all: openhab3 openhab4

openhab3:
	$(call BUILD,34)

openhab4:
	$(call BUILD,40)
