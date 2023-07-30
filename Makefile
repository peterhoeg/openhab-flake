default: openhab3

BUILD = @nix build .\#openhab$(1) .\#openhab$(1)-addons

openhab3:
	$(call BUILD,34)

openhab4:
	$(call BUILD,40)
