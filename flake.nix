{
  description = "openHAB flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05";
    flake-utils.url = "github:numtide/flake-utils";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = { self, nixpkgs, flake-utils, microvm }:
    let
      system = "x86_64-linux";

      supportedSystems = [ system ]; # [ "x86_64-linux" "aarch64-linux" ]

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ self.outputs.overlays.default ];
      };

      lib = nixpkgs.lib.extend (final: prev: { openhab = import ./lib; });

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
      overlays.default = final: prev: {
        openhab = {
          inherit (prev.callPackages ./packages { })
            openhab-cloud
            openhab2 openhab2-v1-addons openhab2-v2-addons
            openhab31 openhab31-addons
            openhab32 openhab32-addons
            openhab33 openhab33-addons
            openhab34 openhab34-addons
            openhab40 openhab40-addons
            openhab41 openhab41-addons
            openhab-stable openhab-stable-addons
            openhab-heartbeat;
        };
      };

      nixosModules.openhab = import ./modules/default.nix;

      nixosConfigurations.openhab-microvm = nixpkgs.lib.nixosSystem
        {
          inherit pkgs system;
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
                mem = 2048;
                volumes = [{
                  mountPoint = "/var";
                  image = "var.img";
                  size = 1024;
                }];
                shares = [{
                  # use "virtiofs" for MicroVMs that are started by systemd
                  proto = "9p";
                  tag = "ro-store";
                  # a host's /nix/store will be picked up so that the
                  # size of the /dev/vda can be reduced.
                  source = "/nix/store";
                  mountPoint = "/nix/.ro-store";
                }];
                socket = "control.socket";
                # relevant for delarative MicroVM management
                hypervisor = "qemu";
                interfaces = [{
                  id = "openhab-net";
                  type = "user";
                  mac = "00:00:00:00:00:01";
                }];
                forwardPorts = [{
                  host.port = 8080;
                  guest.port = 8080;
                }];
              };
            }
          ];
        };

    } // flake-utils.lib.eachSystem supportedSystems (system: {
      packages = pkgs.openhab // { default = pkgs.openhab.openhab-stable; } // {
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

      hydraJobs = pkgs.openhab;
    });
}
