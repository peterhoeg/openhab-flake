{
  description = "openHAB flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-parts.url = "github:hercules-ci/flake-parts";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      microvm,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      flake =
        let
          lib = nixpkgs.lib.extend (final: prev: { openhab = import ./lib; });
        in
        {
          overlays.default = final: prev: {
            openhab = lib.recurseIntoAttrs (prev.callPackages ./packages { });
          };

          nixosModules.openhab = import ./modules/default.nix;

          nixosConfigurations.openhab-microvm = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            pkgs = import nixpkgs {
              system = "x86_64-linux";
              overlays = [ self.overlays.default ];
            };
            modules = [
              self.nixosModules.openhab
              {
                services.openhab = {
                  enable = true;
                  configOnly = false;
                  openFirewall = true;
                };
                system.stateVersion = "23.05";

              }
              microvm.nixosModules.microvm
              {

                networking.hostName = "openhab-microvm";
                users.users.root.password = "";
                services.getty.autologinUser = "root";

                microvm = {
                  # QEMU hangs if memory is exactly 2GB
                  # https://github.com/microvm-nix/microvm.nix/issues/171
                  mem = 2176;
                  volumes = [
                    {
                      mountPoint = "/var";
                      image = "var.img";
                      size = 1024;
                    }
                  ];
                  shares = [
                    {
                      # use "virtiofs" for MicroVMs that are started by systemd
                      proto = "9p";
                      tag = "ro-store";
                      # a host's /nix/store will be picked up so that the
                      # size of the /dev/vda can be reduced.
                      source = "/nix/store";
                      mountPoint = "/nix/.ro-store";
                    }
                  ];
                  socket = "control.socket";
                  # relevant for delarative MicroVM management
                  hypervisor = "qemu";
                  interfaces = [
                    {
                      id = "openhab-net";
                      type = "user";
                      mac = "00:00:00:00:00:01";
                    }
                  ];
                  forwardPorts = [
                    {
                      host.port = 8080;
                      guest.port = 8080;
                    }
                  ];
                };
              }
            ];
          };
        };

      perSystem =
        { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };

          specFile = (pkgs.formats.json { }).generate "hydra.json" {
            main = {
              enabled = 1;
              type = 1;
              hidden = false;
              description = "openHAB flake";
              checkinterval = 600;
              schedulingshares = 1;
              enableemail = false;
              emailoverride = "";
              keepnr = 3;
              flake = "github:peterhoeg/openhab-flake?ref=main";
            };
          };
        in
        {
          packages =
            removeAttrs pkgs.openhab [ "recurseForDerivations" ]
            // {
              default = pkgs.openhab.openhab-stable;
            }
            // {
              openhab-microvm =
                let
                  inherit (self.nixosConfigurations.openhab-microvm) config;
                  # quickly build with another hypervisor if this MicroVM is built as a package
                  hypervisor = "qemu";
                in
                config.microvm.runner.${hypervisor};
            };

          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [ ];
            shellHook = ''
              install -Dm644 ${specFile} $(git rev-parse --show-toplevel)/.ci/${specFile.name}
            '';
          };

          legacyPackages.hydraJobs = pkgs.openhab;
        };
    };
}
