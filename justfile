ARGS := "--keep-going --no-keep-outputs --print-out-paths"
# BUILD = @nix build .\#openhab$(1) .\#openhab$(1)-addons $(ARGS)

# currently openHAB 5.x
default: openhab5

[private]
@_build targets:
  nix build {{ARGS}} {{targets}}

[private]
@_openhab version:
  nix build {{ARGS}} .#openhab{{version}} .#openhab{{version}}-addons

# all targets
all: cloud openhab2 openhab3 openhab4

# build openHAB-cloud
@cloud: (_build ".#openhab-cloud")

# build heartbeat
@heartbeat: (_build ".#openhab-heartbeat")

# build openHAB 2.x
@openhab2: (_build ".#openhab2 .#openhab2-v1-addons .#openhab2-v2-addons")

# build openHAB 3.4.x
openhab3: (_openhab "34")

# build openHAB 4.3.x
openhab4: (_openhab "43")

# build openHAB 5.0.x
openhab5: (_openhab "50")

# Build and run a VM
@vm: (_build ".#openhab-microvm")
  ./result/bin/microvm-run
