ARGS := "--keep-going --no-keep-outputs --print-out-paths"

alias openhab := build

[private]
@_build targets:
    nix build {{ ARGS }} {{ targets }}

[private]
@_openhab version:
    nix build {{ ARGS }} .#openhab{{ version }} .#openhab{{ version }}-addons

# list all targets
[default]
@list:
    just --justfile {{ justfile() }} --list --list-submodules

# all targets
all: cloud openhab2 openhab3 openhab4 openhab5

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

# build openHAB 5.1.x
openhab5: (_openhab "51")

# build openHAB
build: openhab5

alias b := build

# Build and run a VM
@vm: (_build ".#openhab-microvm")
    ./result/bin/microvm-run
