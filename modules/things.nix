{ lib, pkgs, ... }:

let
  inherit (lib) mkOption submodule types;

in
{
  options = rec {
    type = mkOption {
      description = "Thing type";
      type = types.enum [ "Bridge" "Thing" ];
      default = "Thing";
    };

    binding = mkOption {
      description = "Thing binding id";
      type = types.nullOr types.str;
      default = null;
    };

    bridge = mkOption {
      description = "Thing bridge id";
      type = types.nullOr types.str;
      default = null;
    };

    subtype = mkOption {
      description = "Thing subtype";
      type = types.nullOr types.str;
      default = null;
    };

    id = mkOption {
      description = "Thing id";
      type = types.str;
    };

    label = mkOption {
      description = "Thing label";
      type = types.nullOr types.str;
      default = null;
    };

    file = mkOption {
      description = "Which file to put this in";
      type = types.nullOr types.str;
      default = null;
    };

    location = mkOption {
      description = "Thing room/location (optional)";
      type = types.nullOr types.str;
      default = null;
    };

    params = mkOption {
      description = "Thing parameters (optional)";
      type = types.attrs;
      default = { };
    };

    nested = mkOption {
      description = "Is this a nested thing?";
      type = types.bool;
      default = false;
    };

    things = mkOption {
      description = "Things (optional)";
      type = types.listOf (types.submodule (import ./things.nix { inherit lib pkgs; }));
      default = [ ];
    };

    channels = mkOption {
      description = "Channels";
      default = [ ];
      type = types.listOf (types.submodule ({
        options = {
          subtype = mkOption {
            description = "Channel subtype";
            type = types.str;
          };

          id = mkOption {
            description = "Channel id";
            type = types.str;
          };

          label = mkOption {
            description = "Channel label";
            type = types.nullOr types.str;
            default = null;
          };

          params = mkOption {
            description = "Channel parameters";
            type = types.attrs;
          };
        };
      }));
    };
  };
}
