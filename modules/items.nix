{ lib, pkgs, ... }:

let
  inherit (lib) mkOption submodule types;

  itemTypes = [
    "Color"
    "Contact"
    "DateTime"
    "Dimmer"
    "Group"
    "Image"
    "Location"
    "Number"
    "Number:Angle"
    "Number:Dimensionless"
    "Number:Intensity"
    "Number:Length"
    "Number:Pressure"
    "Number:Speed"
    "Number:Temperature"
    "Player"
    "Rollershutter"
    "String"
    "Switch"
  ];

  metaOptions = { };

in
{
  options = rec {
    name = mkOption {
      description = "Item name";
      type = types.str;
    };

    # https://www.openhab.org/docs/configuration/items.html#type
    type = mkOption {
      description = "Item type";
      type = types.enum itemTypes;
    };

    subtype = mkOption {
      description = "Item sub type (for groups)";
      type = types.nullOr (types.enum itemTypes);
      default = null;
    };

    aggregate = mkOption {
      description = "Aggregate function (for groups)";
      type = types.nullOr types.str;
      default = null;
    };

    settings = mkOption {
      description = "Item settings";
      type = types.attrs;
      default = { };
    };

    extraConfig = mkOption {
      description = "Item raw config";
      type = types.lines;
      default = "";
    };

    label = mkOption {
      description = "Item label (optional)";
      type = types.nullOr types.str;
      default = null;
    };

    icon = mkOption {
      description = "Item icon (optional)";
      type = types.nullOr types.str;
      default = null;
    };

    groups = mkOption {
      description = "Item groups (optional)";
      type = types.listOf types.str;
      default = [ ];
    };

    tags = mkOption {
      description = "Item tags (optional)";
      type = types.listOf types.str;
      default = [ ];
    };

    influxdb = {
      key = mkOption {
        description = "Key";
        type = types.str;
        default = "";
      };

      tags = mkOption {
        description = "Tags";
        type = types.attrs;
        default = { };
      };
    };

    file = mkOption {
      description = "Which file to put this in";
      type = types.nullOr types.str;
      # if you notice a message about something accessing `file` without it
      # being defined, then uncomment this. At least you can see *what* it is.
      # default = "xxx_BROKEN_xxx";
    };

    attribs = mkOption {
      description = "Additional attributes";
      type = types.attrs;
    };
  };
}
