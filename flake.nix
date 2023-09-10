{
  description = "openHAB flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
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
          flake = "gitlab:peterhoeg/openhab-flake?ref=main";
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
            openhab-stable openhab-stable-addons
            openhab-heartbeat;
        };
      };

      nixosModules.openhab = import ./modules/default.nix;
    } // flake-utils.lib.eachSystem supportedSystems (system: {
      packages = pkgs.openhab // { default = pkgs.openhab.openhab-stable; };

      devShells.default = pkgs.mkShell {
        nativeBuildInputs = [ ];
        shellHook = ''
          install -Dm644 ${specFile} $(git rev-parse --show-toplevel)/.ci/${specFile.name}
        '';
      };

      hydraJobs = pkgs.openhab;
    });
}
