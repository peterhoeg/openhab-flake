{ config, lib, pkgs, ... }:

let
  inherit (lib)
    concatStringsSep concatMapStringsSep
    mapAttrs mapAttrsToList
    optional optionals optionalString
    toLower
    mkDefault mkEnableOption mkIf mkForce mkMerge mkOption literalExample types;

  inherit (lib.versions) majorMinor;

  inherit (import ./helpers.nix { inherit config lib pkgs; })
    attrsToItem attrsToThing
    attrsToFile attrsToPlainFile
    attrsToPlainText attrsToQuotedText
    attrsToConfig attrsToSitemap
    itemFileName thingFileName
    entityName macToName
    keyPrefix isV2 isV2dot5 isV3 isV3dot1 isV3dot2 isV3dot3 wrapBinary;

  cfg = config.services.openhab;

  json = pkgs.formats.json { };
  yaml = pkgs.formats.yaml { };

  packages = pkgs.callPackages <pkgs/openhab> { };

  javaBin =
    if cfg.java.elevatePermissions
    then "/run/wrappers/bin/java" # we need to make sure that we use the wrapper
    else "${cfg.java.package}/bin/java";

  privateDir = "/private/openhab";

  libDir = "/var/lib/openhab";

  dirName = builtins.baseNameOf libDir;

  versionMarker = "${libDir}/.version";

  fileExt = type:
    {
      persistence = "persist";
      rules = "rules";
      services = "cfg";
      sitemaps = "sitemap";
      transform = "map";
    }."${type}" or type;

  filePath = type: name:
    "${type}/${name}.${fileExt type}";

  # mapAttrsToText = k: v: list:
  #   lib.concatStringsSep "\n" (lib.mapAttrsToList () )

  writeFormattedContents = fn: textOrAttrs:
    if builtins.isAttrs textOrAttrs
    then fn textOrAttrs
    else textOrAttrs;

  cfgDrv = pkgs.runCommand "openhab-config" { } (
    let
      catToFile = source: target: ''
        cat ${source} >> ${target}
        echo -e -n "\n\n" >> ${target}
      '';

      fileName = storePath:
        concatStringsSep "" (lib.drop 1 (lib.splitString "-" storePath));

      processAttr = fn: attr:
        concatStringsSep "\n" (mapAttrsToList fn attr);

      processList = fn: list:
        concatMapStringsSep "\n" fn list;

      whiteList = pkgs.writeText "exec.whitelist" (concatStringsSep "\n" cfg.execWhiteList);

    in
    ''
      dir=$out/etc/openhab

      # addons.cfg
      install -Dm444 ${attrsToPlainFile cfg.initialAddons "addons.cfg"} $dir/conf/services/addons.cfg

      # html
      ${concatMapStringsSep "\n" (e: "install -Dm444 ${e} $dir/conf/html/${fileName e}") cfg.staticFiles}

      # exec whitelist
      install -Dm444 ${whiteList} $dir/conf/misc/${whiteList.name}

    '' + processAttr
      (type: items:
        let
          writeContents =
            writeFormattedContents attrsToPlainText;

        in
        concatStringsSep "\n" (mapAttrsToList
          (item: contents: ''
            install -Dm444 ${pkgs.writeText "${item}.${fileExt type}" (writeContents contents)} $dir/conf/${filePath type item}
          '')
          items))
      cfg.conf
    + ''
      mkdir -p $dir/conf/{items,rules,sitemaps,things,transform}
    ''
    # items
    + processList
      (item:
        let
          name = toLower "$dir/conf/items/${item.file}.items";
          file = pkgs.writeText (itemFileName item) (attrsToItem item);
        in
        catToFile file name)
      cfg.items
    # rules
    + processList
      (item: ''
        install -Dm444 ${item} ${toLower "$dir/conf/rules/${builtins.baseNameOf item}"}
      '')
      cfg.rules
    # sitemaps
    + processAttr
      (n: v:
        let
          fname = "${n}.sitemap";
          name = "$dir/conf/sitemaps/${fname}";
          file = pkgs.writeText fname (attrsToSitemap n v);
        in
        catToFile file name)
      cfg.sitemaps
    # things
    + processList
      (thing:
        let
          name = "$dir/conf/things/${if (thing.file != null) then thing.file else thing.binding}.things";
          file = pkgs.writeText (thingFileName thing) (attrsToThing thing);
        in
        catToFile file name)
      cfg.things
    # jruby rules and scripts
    + processList
      (e:
        let name = builtins.baseNameOf e;
        in
        ''
          install -Dm444 ${e} $dir/conf/automation/jsr223/ruby/personal/${name}
        ''
      )
      cfg.jruby.rules
    # jruby libs
    + processList
      (e:
        let name = builtins.baseNameOf e;
        in
        ''
          install -Dm444 ${e} $dir/conf/automation/lib/ruby/${name}
        ''
      )
      cfg.jruby.libs
    # transform scripts
    + processList
      (script:
        let name = builtins.baseNameOf script.file;
        in
        ''
          install -Dm444 ${script.file} $dir/conf/transform/${script.directory}/${name}
        ''
      )
      cfg.transformScripts
    # userdata/
    + processList
      (e:
        let
          writeContents =
            writeFormattedContents attrsToConfig;
        in
        ''
          install -Dm444 ${pkgs.writeText (builtins.baseNameOf e.name) (writeContents e.contents)} $dir/userdata/${e.name}
        '')
      cfg.settings
    # users
    + ''
      install -Dm444 ${json.generate "users_override.json" (mapAttrs (k: v: (user k v)) cfg.users.users)} $dir/userdata/users_override.json
    ''
  );

  setupScript = pkgs.writeShellScript "openhab-setup"
    (
      let
        v2log = [
          { key = "log4j2.rootLogger.level"; value = cfg.logging.logLevel; }
          { key = "log4j2.rootLogger.appenderRefs"; value = "stdout"; }
          { key = "log4j2.rootLogger.appenderRef.stdout.ref"; value = "STDOUT"; }
          { key = "log4j2.appender.console.layout.pattern"; value = "<%level{FATAL=2, ERROR=3, WARN=4, INFO=5, DEBUG=6, TRACE=7}>[%-36.36c] - %m%n"; }
        ];

      in
      ''
        set -eEuo pipefail

        DIST_DIR=${cfg.finalPackage}/share/openhab

        # Use this in case of problems with the generated configuration
        if [ ''${OPENHAB_SKIP_SETUP:-0} -eq 1 ]; then
          exit 0
        fi

        args=(--no-preserve=mode --remove-destination -R)

        wipe_config() {
          echo "Wiping configuration"
          rm -rf \
            ${libDir}/.reset \
            $OPENHAB_CONF \
            $OPENHAB_USERDATA
          touch ${libDir}/.first_run
        }

        wipe_cache() {
          echo "Wiping cache"
          rm -rf \
            ${libDir}/.reset_cache \
            /var/cache/${dirName}/* \
            $OPENHAB_USERDATA/etc \
            $OPENHAB_USERDATA/tmp/*
        }

        if [ -f ${libDir}/.reset ]; then
          wipe_config
          wipe_cache
        fi

        if [ -f ${libDir}/.reset_cache ]; then
          wipe_cache
        fi

        if [ -e "${versionMarker}" ]; then
          if [ "${majorMinor cfg.package.version}" != "$(head -n1 ${versionMarker})" ]; then
            echo "Detected up- or downgrade"
            wipe_cache
          fi
        fi

        test -d $OPENHAB_USERDATA || touch ${libDir}/.first_run

        # remove all symlinks to prepare for new links
        for d in $OPENHAB_CONF $OPENHAB_USERDATA; do
          test -e $d && find $d -type l -delete
        done

        # Copy in default configuration when on a blank configuration
        if [ ! -d $OPENHAB_CONF ]; then
          cp ''${args[@]} --dereference $DIST_DIR/conf $OPENHAB_CONF
        fi

        if [ ! -d $OPENHAB_USERDATA ]; then
          cp ''${args[@]} --dereference $DIST_DIR/userdata $OPENHAB_USERDATA
        fi

        # if etc was blown away by an up- or downgrade
        if [ ! -d $OPENHAB_USERDATA/etc ]; then
          cp ''${args[@]} --dereference $DIST_DIR/userdata/etc $OPENHAB_USERDATA/etc
        fi

        rm -rf $OPENHAB_USERDATA/cache
        ln -sf /var/cache/${dirName} $OPENHAB_USERDATA/cache

        # recursively copy and symlink files into place
        cp ''${args[@]} -sf ${cfgDrv}/etc/openhab/* ${libDir}/

      '' + optionalString cfg.users.enable ''
        file=$OPENHAB_USERDATA/jsondb/users.json
        if [ -e $file ]; then
          t=$(mktemp)
          cat $file ${libDir}/userdata/users_override.json | ${lib.getBin pkgs.jq}/bin/jq -s add > $t
          mv $t $file
        else
          install -Dm644 ${libDir}/userdata/users_override.json $file
        fi

      '' + optionalString (isV2 && cfg.logging.toStdout) ''
        file=$OPENHAB_USERDATA/etc/org.ops4j.pax.logging.cfg
        if [ -e $file ]; then
          ${concatMapStringsSep "\n" (e: ''${pkgs.crudini}/bin/crudini --set $file "" "${e.key}" "${e.value}"'') v2log}
        fi

      '' + optionalString (isV3 && cfg.logging.toStdout) ''
        file=$OPENHAB_USERDATA/etc/log4j2.xml

        if [ -e $file ]; then
          # http://xmlstar.sourceforge.net/doc/UG/ch04s03.html
          ${pkgs.xmlstarlet}/bin/xml ed --inplace \
            --update "/Configuration/Appenders/Console/PatternLayout/@pattern" \
            -v '${cfg.logging.format}' \
            --update "/Configuration/Loggers/Root/@level" \
            -v '${cfg.logging.logLevel}' \
            --update "/Configuration/Loggers/Root/AppenderRef[@ref='LOGFILE']/@ref" \
            -v 'STDOUT' \
            $file
        fi
      ''
    );

  waitScript = port:
    pkgs.writeShellScript "wait-for-openhab" (
      let
        port' = toString port;

      in
      ''
        export PATH=$PATH:${lib.makeBinPath (with pkgs; [ coreutils gnugrep iproute ])}

        timeout 60 ${pkgs.runtimeShell} -c \
          'while ! ss -H -t -l -n sport = :${port'} | grep -q "^LISTEN.*:${port'}"; do sleep 1; done'
      ''
    );

  ruleReloadScript = pkgs.writeShellScript "openhab-rules-reload " ''
    set -eEuo pipefail
    # trigger rules reloading. This file is empty.
    touch ${libDir}/conf/rules/trigger.rules
  '';

  storeVersionScript = pkgs.writeShellScript "openhab-store-version" ''
    set -eEuo pipefail
    echo -n "${majorMinor cfg.package.version}" > ${versionMarker}
  '';

  user = k: v: {
    class = "org.openhab.core.auth.ManagedUser";
    value = {
      name = k;
      inherit (v) passwordHash passwordSalt roles;
      sessions = [ ];
      apiTokens = map (e: { inherit (e) name apiToken createdTime scope; }) v.tokens;
    };
  };

  bluetoothDbus = pkgs.writeTextFile rec {
    name = "openhab-bluetooth.conf";
    text = ''
      < ?xml version= "1.0" encoding="UTF-8"?>
      <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
      "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
      <busconfig>
        <policy group="bluetooth">
          <!--
          <allow own="org.bluez"/>
          -->
          <allow send_destination="org.bluez"/>
          <allow send_interface="org.bluez.Agent1"/>
          <allow send_interface="org.bluez.MediaEndpoint1"/>
          <allow send_interface="org.bluez.MediaPlayer1"/>
          <allow send_interface="org.bluez.Profile1"/>
          <allow send_interface="org.bluez.GattCharacteristic1"/>
          <allow send_interface="org.bluez.GattDescriptor1"/>
          <allow send_interface="org.bluez.LEAdvertisement1"/>
          <allow send_interface="org.freedesktop.DBus.ObjectManager"/>
          <allow send_interface="org.freedesktop.DBus.Properties"/>
          <allow send_interface="org.mpris.MediaPlayer2.Player"/>
        </policy>

        <policy group="bluetooth">
          <allow send_destination="org.bluez"/>
        </policy>
      </busconfig>
    '';
    destination = "/share/dbus-1/system.d/${name}";
  };

in
{
  meta.maintainers = with lib.maintainers; [ peterhoeg ];

  options.services.openhab = {
    enable = mkEnableOption "openHAB - home automation";

    debug = mkEnableOption "debug";

    configOnly = mkEnableOption "only generate the configuration without running anything. Used for testing things out locally";

    logToRamdisk = mkOption {
      description = ''
        Log to ramdisk instead of hitting the disk with continuous events.

        Makes sense if openHAB is running on a machine with SD or eMMC persistent storage.
      '';
      type = types.bool;
      default = false;
    };

    bluetooth.enable = mkEnableOption "Bluetooth support";

    zigbee = {
      enable = mkEnableOption "Zigbee support";

      device = mkOption {
        description = "Device name";
        type = types.str;
      };

      vendor = mkOption {
        description = "Device name";
        type = types.str;
      };

      product = mkOption {
        description = "Device name";
        type = types.str;
      };

      networkKey = mkOption {
        description = "Network key";
        type = types.listOf types.str;
      };

      panId = mkOption {
        description = "Pan id";
        type = types.int;
      };

      extendedPanId = mkOption {
        description = "Extended pan id";
        type = types.listOf types.str;
      };
    };

    withDefaultAddons = mkOption {
      description = "Include default addons";
      type = types.bool;
      default = true;
    };

    package = mkOption {
      default = packages.openhab-stable;
      type = types.package;
      description = "OpenHAB package to use.";
    };

    finalPackage = mkOption {
      default = wrapBinary cfg.package
        (cfg.addons
          ++ optionals (cfg.withDefaultAddons && isV2)
          (with packages; [ openhab2-v1-addons openhab2-v2-addons ])
          ++ optionals (cfg.withDefaultAddons && isV3dot1)
          (with packages; [ openhab31-addons ])
          ++ optionals (cfg.withDefaultAddons && isV3dot2)
          (with packages; [ openhab32-addons ])
          ++ optionals (cfg.withDefaultAddons && isV3dot3)
          (with packages; [ openhab33-addons ])
        );
      type = types.package;
      readOnly = true;
    };

    addons = mkOption {
      description = "Addons";
      type = types.listOf types.package;
      default = [ ];
    };

    logging = {
      toStdout = mkOption {
        description = "Log to stdout instead of files";
        type = types.bool;
        default = true;
      };

      format = mkOption {
        description = "Format when logging to stdout";
        type = types.str;
        default = "[%-5.5p] [%-36.36c] - %m%n";
      };

      logLevel = mkOption {
        description = "Loglevel when logging to stdout";
        type = types.enum [ "ALL" "TRACE" "DEBUG" "INFO" "WARN" "ERROR" "FATAL" "OFF" ];
        default = "INFO";
      };
    };

    initialAddons = mkOption {
      default = { };
      type = types.attrs;
      example = literalExample ''
        {
        package = "standard";
        remote = true;
        action = [
          "mail"
        ];
        binding = [
          "airquality"
          "exec"
        ];
        misc = [
          "ruleengine"
        ];
        persistence = [
          "influxdb"
        ];
        transformation = [
          "exec"
        ];
        ui = [
          "basic"
          "paper"
        ];
        voice = [
          "picotts"
        ];
      '';
      description = ''
        The various types of addons to install and activate during the first
        run. Refer to the addons.cfg file distributed with openHAB for details.
        </para>
        <para>
        This list is only used on the first run of openHAB.
      '';
    };

    # things = {
    #   astro = \'\'
    #     Thing astro:moon:local "Moon" @ "Outside" [geolocation="123,123"]
    #     Thing astro:sun:local  "Sun" @ "Outside"  [geolocation="123,123"]
    #   \'\';
    # };

    conf = mkOption {
      default = { };
      type = types.attrs;
      example = literalExample ''
          {
          services = {
          mail = {
            hostname = "smtp.example.com";
            from = "openHAB <openhab@example.com>";
          };

          runtime = {
            "discovery.kodi:background" = true;
          };
        };
        }
      '';
      description = ''
        Everything that goes into the conf/ directory, *except*: items and things
      '';
    };

    staticFiles = mkOption {
      description = "Static files for the html directory";
      type = types.listOf types.path;
      default = [ ];
    };

    execWhiteList = mkOption {
      description = "Whitelisted commands for the exec binding";
      type = types.listOf types.str;
      default = [ ];
    };

    itemThingFiles = mkOption {
      description = "Files with items and things";
      type = types.listOf types.path;
      default = [ ];
    };

    settings = mkOption {
      default = [ ];
      type = types.listOf types.attrs;
      example = literalExample ''
        [
        {
          name = "config/${lib.replaceStrings [ "." ] [ "/" ] keyPrefix}/core/i18nprovider.config";
          contents = {
            "service.pid" = "${keyPrefix}.i18nprovider";
            language = "en";
            location = "123.123,123.123";
            region = "DK";
            timezone = config.time.timeZone;
          };
        }
        ]
      '';
      description = ''
        TODO: document me
      '';
    };

    items = mkOption {
      default = [ ];
      description = "Items";
      type = types.listOf (types.submodule (import ./items.nix { inherit lib pkgs; }));
    };

    things = mkOption {
      default = [ ];
      description = "Things";
      type = types.listOf (types.submodule (import ./things.nix { inherit lib pkgs; }));
    };

    sitemaps = mkOption {
      default = [ ];
      description = "Sitemaps";
      type = types.attrsOf (types.submodule (import ./sitemaps.nix { inherit lib pkgs; }));
    };

    rules = mkOption {
      description = "Files with DSL rules";
      type = types.listOf types.path;
      default = [ ];
    };

    jruby = {
      rules = mkOption {
        description = "JRuby rules";
        type = types.listOf types.path;
        default = [ ];
      };

      libs = mkOption {
        description = "JRuby libs";
        type = types.listOf types.path;
        default = [ ];
      };
    };

    transformScripts = mkOption {
      description = "Files with transformation scripts";
      type = types.listOf (types.submodule {
        options = {
          file = mkOption {
            description = "File";
            type = types.path;
          };

          directory = mkOption {
            description = "Directory";
            type = types.str;
          };
        };
      });
      default = [ ];
    };

    java = {
      package = mkOption {
        # default = if isV2 then pkgs.jre8_headless else pkgs.jdk11_headless;
        default = (if isV2 then pkgs.zulu8 else pkgs.zulu).override { gtkSupport = false; };
        example = "pkgs.oraclejdk8";
        type = types.package;
        description = ''
          By default we are using OpenJDK as the Java run-time due to it being
          open source, but if you are using java 8 *and* want to connect to an
          instance of OpenHAB cloud either self-hosted with Let's Encrypt
          certificates or myopenhab.org, you <emphasis>will</emphasis> need the
          Oracle JRE instead due to OpenJDK missing support for various
          encryption providers.
        '';
      };

      elevatePermissions = mkOption {
        default = false;
        type = types.bool;
        description = ''
          Some bindings will require the java process to have additional
          permissions. Enabling this will configure a wrapper that does that.
        '';
      };

      memoryMax = mkOption {
        description = "Maximum memory to use. It is pre-allocated up front to speed up openHAB launch";
        type = types.str;
        default = "768m";
      };

      metaMax = mkOption {
        description = "Maximum memory to use for metaspace";
        type = types.str;
        default = "384m";
      };

      additionalArguments = mkOption {
        default = [ ];
        type = types.listOf types.str;
        description = ''
          Additional arguments to pass to the java process.
        '';
      };
    };

    ports = {
      http = mkOption {
        description = "The port on which to listen for HTTP.";
        type = types.port;
        default = 8080;
      };

      https = mkOption {
        description = "The port on which to listen for HTTPS.";
        type = types.port;
        default = 8443;
      };
    };

    openFirewall = mkEnableOption "Open the firewall for the specified ports.";

    keyFiles = mkOption {
      description = "Files to copy in from /private/openhab";
      default = [ ];
      type = types.listOf
        (types.submodule {
          options = {
            name = mkOption {
              description = "File name to copy from /private/openhab";
              type = types.str;
            };

            path = mkOption {
              description = "Path under ${libDir} to copy to";
              type = types.str;
            };
          };
        });
    };

    # https://community.openhab.org/t/is-openhab-3-multiuser/111277/5
    users = {
      enable = mkEnableOption "managed users";

      users = mkOption {
        description = "Users";
        default = { };
        type = types.attrsOf
          (types.submodule {
            options = {
              passwordHash = mkOption {
                description = "Password hash";
                type = types.str;
              };

              passwordSalt = mkOption {
                description = "Password salt";
                type = types.str;
              };

              roles = mkOption {
                description = "Roles";
                type = types.listOf types.str;
                default = [ ];
              };

              tokens = mkOption {
                description = "API tokens";
                type = types.listOf
                  (types.submodule {
                    options = {
                      name = mkOption {
                        description = "Name";
                        type = types.str;
                      };

                      apiToken = mkOption {
                        description = "Token";
                        type = types.str;
                      };

                      createdTime = mkOption {
                        description = "Creation time";
                        type = types.str;
                      };

                      scope = mkOption {
                        description = "Scope";
                        type = types.str;
                        default = "";
                      };
                    };
                  });
                default = [ ];
              };
            };
          });
      };
    };

    workarounds = {
      ruleLoading = mkEnableOption "work around rule loading not happening";

      lockDir = mkEnableOption "work around lock directory permissions";

      # openHAB v2 sometimes stops reading temperatures via MQTT, so restart openHAB when we
      # typically do not need it
      restart = {
        onDeploy = mkEnableOption "restarting openHAB when deploying new configuration";

        scheduled = {
          enable = mkEnableOption "scheduled restart to work around MQTT messages not being sent";

          restartAt = mkOption {
            description = "Restart daily at";
            type = types.str;
            default = "*-*-* 08:00:00";
          };
        };
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf cfg.debug {
      services.openhab.logging.logLevel = mkForce "DEBUG";
    })

    {
      services.openhab = {
        items = lib.flatten
          (map
            (e: (import e { inherit config lib pkgs; }).items)
            cfg.itemThingFiles);

        things = lib.flatten
          (map
            (e: (import e { inherit config lib pkgs; }).things)
            cfg.itemThingFiles);
      };
    }

    (mkIf cfg.configOnly {
      environment.etc."openhab".source = cfgDrv;
    })

    (mkIf (!cfg.configOnly) {
      hardware.bluetooth = mkIf cfg.bluetooth.enable {
        inherit (cfg.bluetooth) enable;
        # package = pkgs.bluezFull;
        powerOnBoot = true;
        # https://github.com/Vudentz/BlueZ/blob/master/src/main.conf
        settings = {
          General = {
            ControllerMode = "le"; # dual bredr le  - now we have LE support
            FastConnectable = true;
          };
          Controller = { };
          GATT = { };
        };
      };

      networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall (with cfg.ports; [
        http
        https
        # too dangerous to open this up everywhere
        # 8080 # REST API
      ]);

      security.wrappers = lib.mkIf cfg.java.elevatePermissions {
        java = {
          owner = "root";
          group = "root";
          source = "${cfg.java.package}/bin/java";
          capabilities = "cap_net_raw,cap_net_admin=+eip cap_net_bind_service=+ep";
        };
      };

      services.dbus.packages = optional cfg.bluetooth.enable bluetoothDbus;

      services.udev = {
        # extraRules = lib.concatStringsSep ", " ([
        #   ''ACTION=="add"''
        #   ''KERNEL=="ttyACM?"''
        #   ''SUBSYSTEM=="tty"''
        #   ''ATTRS{idVendor}=="${cfg.zigbee.vendor}"''
        #   ''ATTRS{idProduct}=="${cfg.zigbee.product}"''
        #   ''SYMLINK+="${cfg.zigbee.device}" ''
        #   ''TAG+="systemd" ''
        # ]
        # ++ optional (!cfg.zigbee.enable) ''ENV{SYSTEMD_WANTS}="zigbee2mqtt.service"''
        # );
      };

      systemd = {
        services =
          let
            documentation = [
              https://www.openhab.org/docs/
              https://community.openhab.org
            ];

            environment = {
              JAVA = javaBin;
              JAVA_HOME = cfg.java.package;
              JAVA_OPTS = lib.concatStringsSep " " ([
                "-XshowSettings:vm"
                "-Xms${cfg.java.memoryMax}"
                "-Xmx${cfg.java.memoryMax}"
                "-XX:MaxMetaspaceSize=${cfg.java.metaMax}"
              ] ++ cfg.java.additionalArguments);
              KARAF_DEBUG = mkIf cfg.enable "true";
              # upstream's launcher script doesn't use exec
              # unless running in daemon mode so we force it here
              # KARAF_EXEC = "exec";
              OPENHAB_CONF = "${libDir}/conf";
              OPENHAB_USERDATA = "${libDir}/userdata";
              OPENHAB_HOME = "${cfg.finalPackage}/share/openhab";
              OPENHAB_LOGDIR = "/var/log/openhab";
              OPENHAB_HTTP_PORT = toString cfg.ports.http;
              OPENHAB_HTTPS_PORT = toString cfg.ports.https;
            };

            wantedBy = [ "openhab.target" ];

            commonServiceConfig = {
              DynamicUser = true;
              User = "openhab";
              Group = "openhab";
              SyslogIdentifier = "%N";
              PrivateTmp = true;
              ProtectHome = "tmpfs";
              ProtectControlGroups = true;
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectSystem = "strict";
              RemoveIPC = true;
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
                "AF_NETLINK"
              ];
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              SystemCallArchitectures = "native";
              CacheDirectory = dirName;
              StateDirectory = dirName;
              WorkingDirectory = libDir;
              # TODO: move keys somewhere else
              SupplementaryGroups = [
                "openhab-keys"
              ]
              ++ optional cfg.bluetooth.enable "bluetooth";
              Slice = "openhab.slice";
            };

          in
          {
            openhab-keys = rec {
              description = "openHAB - copy in keys";
              inherit documentation environment wantedBy;
              after = [ "openhab-setup.service" ];
              wants = after;
              script = ''
                set -eEuo pipefail
                test -e ${privateDir} || exit 0

                _copy() {
                  source="$1"
                  target="$2"

                  install --preserve-timestamps -Dm666 "$source" "$target"
                }

                _conditional_copy() {
                  source="${privateDir}/$1"
                  target="${libDir}/$2/$1"

                  if [ -e ${libDir}/.first_run ]; then
                    _copy "$source" "$target"
                  elif [ ! -e "$target" ]; then
                    _copy "$source" "$target"
                  fi
                }

              '' + lib.concatMapStringsSep "\n"
                (e: ''_conditional_copy "${e.name}" "${e.path}"'')
                cfg.keyFiles + ''

                rm -f ${libDir}/.first_run
              '';

              serviceConfig = commonServiceConfig // {
                Type = "oneshot";
                PrivateDevices = true;
                PrivateNetwork = true;
                SyslogIdentifier = "openhab-keys";
              };
            };

            openhab-setup = rec {
              description = "openHAB - copy and link config files into place";
              inherit documentation environment wantedBy;
              restartTriggers = [ cfgDrv ];
              serviceConfig = commonServiceConfig // {
                Type = "oneshot";
                ExecStart = setupScript;
                PrivateDevices = true;
                PrivateNetwork = true;
                SyslogIdentifier = "openhab-setup";
              };
            };

            openhab = rec {
              description = "openHAB ${toString cfg.package.version}";
              inherit documentation environment wantedBy;
              wants = [ "network-online.target" ];
              requires = [ "openhab-setup.service" ];
              after = wants ++ requires;
              path = [
                "/run/wrappers"
                cfg.java.package
                pkgs.ffmpeg
                pkgs.ncurses # needed by the infocmp program
              ];
              restartTriggers = [ ]
                # we do NOT need to restart with OH 3 as it will pick up changed files
                ++ optionals isV2 [ cfgDrv setupScript ]
                ++ optionals cfg.workarounds.restart.onDeploy [ cfgDrv ];

              serviceConfig = commonServiceConfig // {
                Type =
                  if (lib.versionAtLeast pkgs.systemd.version "240")
                  then "exec"
                  else "simple";
                SupplementaryGroups = commonServiceConfig.SupplementaryGroups ++ [
                  "audio"
                  "dialout"
                  "tty"
                ] ++ optional cfg.workarounds.lockDir "uucp"; # needed for /run/lock with zigbee
                AmbientCapabilities = [
                  # TODO: find out why it fails without all capabilities
                  "~"
                  # "CAP_NET_ADMIN"
                  # "CAP_NET_BIND_SERVICE"
                  # "CAP_NET_RAW"
                ];
                ExecStart = concatStringsSep " " ([
                  "${cfg.finalPackage}/bin/openhab"
                  "run"
                ] ++ optional cfg.debug "-v -l 4"
                );
                ExecStop = "${cfg.finalPackage}/bin/openhab stop";
                ExecStartPost = [
                  (waitScript cfg.ports.http)
                  storeVersionScript
                ] ++ optional cfg.workarounds.ruleLoading ruleReloadScript;
                SuccessExitStatus = "0 143";
                RestartSec = "5s";
                Restart = "on-failure";
                TimeoutStopSec = "120";
                LimitNOFILE = "102642";
                ReadWriteDirectories = [
                  "/run/lock"
                  "/var/lock"
                ];
              } // (if cfg.logToRamdisk then {
                TemporaryFileSystem = "/var/log/openhab";
              } else {
                LogsDirectory = dirName;
              });
            };

            openhab-restart = mkIf cfg.workarounds.restart.scheduled.enable {
              description = "Restart openHAB so our temperature readings work";
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${pkgs.systemd}/bin/systemctl restart openhab.service";
                PrivateNetwork = true;
                PrivateTmp = true;
              };
              startAt = cfg.workarounds.restart.restartAt;
            };

            # TODO: This needs to go with 21.03 as it should be upstreamed then
            bluetooth = mkIf cfg.bluetooth.enable {
              serviceConfig.ExecStart = [
                ""
                "${lib.getBin config.hardware.bluetooth.package}/libexec/bluetooth/bluetoothd -f /etc/bluetooth/main.conf --noplugin=sap"
              ];
            };
          };

        targets.openhab = {
          description = "openHAB";
          wantedBy = [ "multi-user.target" ];
        };

        tmpfiles.rules = lib.mkIf cfg.workarounds.lockDir [
          "d /run/lock 0775 root uucp -"
        ];
      };

      users.groups = {
        bluetooth = mkIf cfg.bluetooth.enable { };
        openhab-keys = { };
      };
    })
  ]);
}
