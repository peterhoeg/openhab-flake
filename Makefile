ARGS ?= --keep-going --no-keep-outputs --print-out-paths
BUILD = @nix build .\#openhab$(1) .\#openhab$(1)-addons $(ARGS)

default: all

all: cloud openhab2 openhab3 openhab4

cloud:
	@nix build .\#openhab-cloud

heartbeat:
	@nix build .\#openhab-heartbeat

openhab2:
	@nix build .\#openhab2 .\#openhab2-v1-addons .\#openhab2-v2-addons

openhab3:
	$(call BUILD,34)

openhab4:
	$(call BUILD,43)

openhab5:
	$(call BUILD,50)

vm:
	@nix build .#openhab-microvm && ./result/bin/microvm-run
