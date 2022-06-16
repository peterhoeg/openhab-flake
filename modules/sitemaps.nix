{ lib, pkgs, ... }:
let
  inherit (lib) mkOption submodule types;

in
{
  options = rec {
    name = mkOption {
      description = "Sitemap name";
      type = types.str;
    };

    label = mkOption {
      description = "Sitemap label";
      type = types.str;
    };

    # TODO: this should be handling proper stuff but as sitemaps are going away,
    # let's just keep it easy
    content = mkOption {
      description = "Sitemap Contents";
      type = types.lines;
    };
  };
}
