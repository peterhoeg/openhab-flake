{ config, lib, pkgs, ... }:

let
  ohCfg = config.services.openhab;
  cfg = ohCfg.habapp;

  inherit (lib)
    concatStringsSep concatMapStringsSep
    optional optionals optionalString
    toLower
    mkDefault mkEnableOption mkIf mkOption literalExample types;

  yaml = pkgs.formats.yaml { };

  dirName = "habapp";

  habappDefaults = {
    directories = {
      logging = "/var/log/${dirName}";
    };
    openhab = {
      ping = {
        enabled = true;
        item = "habapp_ping";
      };
      connection = {
        host = "localhost";
        port = config.services.openhab.ports.http;
      };
      general.wait_for_openhab = true;
    };
  };

  dir = "/var/lib/${dirName}";

  finalCfg = lib.recursiveUpdate habappDefaults cfg.settings;

  cfgFile = yaml.generate "config.yml" finalCfg;

  setup = pkgs.writeShellScript "habapp-setup" (''
    set -eEuo pipefail

    # it must be RW, so we cannot do this in our regular cfgDrv
    install -Dm644 ${cfgFile} ${dir}/${cfgFile.name}
    mkdir -p ${dir}/{config,lib,params,rules}
    find ${dir} -mindepth 1 -type l -delete

  ''
  + lib.concatMapStringsSep "\n"
    (e: "ln -sf ${e} ${dir}/rules/${builtins.baseNameOf e}")
    cfg.rules);

in
{
  meta.maintainers = with lib.maintainers; [ peterhoeg ];

  options.services.openhab.habapp = {
    enable = mkEnableOption "HABApp";

    package = mkOption {
      description = "HABApp package";
      type = types.package;
      default = (import <nixos-unstable> { }).callPackage <pkgs/habapp> { };
    };

    settings = mkOption {
      description = "HABApp settings";
      type = yaml.type;
      default = { };
    };

    rules = mkOption {
      description = "Rules";
      type = types.listOf types.path;
      default = [ ];
    };
  };

  config = mkIf cfg.enable {
    systemd.services.habapp = {
      description = "HABApp";
      after = [ "openhab.service" ];
      wants = [ "openhab.service" ];
      wantedBy = [ "openhab.target" ];
      serviceConfig = {
        Type = "exec";
        User = "habapp";
        Group = "habapp";
        DynamicUser = true;
        ExecStartPre = setup;
        ExecStart = "${cfg.package}/bin/habapp -c ${dir}";
        StateDirectory = dirName;
        WorkingDirectory = dir;
        Slice = "openhab.slice";
        TemporaryFileSystem = habappDefaults.directories.logging;
      } // (if ohCfg.logToRamdisk then {
        TemporaryFileSystem = "/var/log/${dirName}";
      } else {
        LogsDirectory = dirName;
      });
    };
  };
}
