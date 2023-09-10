{ config, lib, pkgs, ... }:

let
  inherit (lib)
    concatStringsSep concatMapStringsSep
    mapAttrs mapAttrsToList recursiveUpdate
    optionals optionalString optionalAttrs
    getBin getExe toLower
    mkDefault mkEnableOption mkIf mkForce mkMerge mkOption literalExample types;

  inherit (lib.versions) majorMinor;

  inherit (import ../lib/helpers.nix { inherit config lib pkgs; })
    attrsToItem attrsToThing
    attrsToFile attrsToPlainFile
    attrsToPlainText attrsToQuotedText
    attrsToConfig attrsToSitemap
    itemFileName thingFileName
    entityName macToName
    keyPrefix isV2 isV2dot5 isV3 isV3dot1 isV3dot2 isV3dot3 isV3dot4 wrapBinary;

  cfg = config.services.openhab;

  json = pkgs.formats.json { };
  yaml = pkgs.formats.yaml { };

  packages = pkgs.openhab;

  javaBin =
    if cfg.java.elevatePermissions
    then "/run/wrappers/bin/java" # we need to make sure that we use the wrapper
    else "${cfg.java.package}/bin/java";

  privateDir = "/private/openhab";

  libDir = "/var/lib/openhab";

  rulesDirs = {
    dsl = "${libDir}/conf/rules";
    ruby = "${libDir}/conf/automation/jsr223/ruby/personal";
  };
  rulesTmpDir = "${libDir}/tmp/rules";

  dirName = builtins.baseNameOf libDir;

  restartMarker = "${libDir}/.restart";
  heartbeatMarker = "${libDir}/.heartbeat";
  versionMarker = "${libDir}/.version";
  # we could also just use majorMinor but I *think* we need to do our cache
  # dance when changing the patch version.
  versionTag = cfg.package.version;

  sortByName = list:
    lib.sort (a: b: a.name < b.name) list;

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

  writeFormattedContents = fn: textOrAttrs:
    if builtins.isAttrs textOrAttrs
    then fn textOrAttrs
    else textOrAttrs;

  cfgDrv =
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
    pkgs.runCommandLocal "openhab-config" { } (''
      dir=$out/etc/openhab

      # set -x

      # addons.cfg
      install -Dm444 ${attrsToPlainFile cfg.initialAddons "addons.cfg"} $dir/conf/services/addons.cfg

      # html
      ${concatMapStringsSep "\n" (e: "install -Dm444 ${e} $dir/conf/html/${fileName e}") cfg.staticFiles}

      # exec whitelist
      install -Dm444 ${whiteList} $dir/conf/misc/${whiteList.name}

    '' + processAttr
      (type: items:
        let
          writeContents = writeFormattedContents attrsToPlainText;

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
      (sortByName cfg.items)
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
          install -Dm444 ${e} $dir/${lib.removePrefix libDir rulesDirs.ruby}/${name}
        ''
      )
      cfg.jruby.rules
    # jruby libs
    + processList
      (e:
        let name = builtins.baseNameOf e;
        in
        ''
          install -Dm444 ${e} $dir/conf/automation/ruby/lib/${name}
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
        let writeContents = writeFormattedContents attrsToConfig;
        in
        ''
          install -Dm444 ${pkgs.writeText (builtins.baseNameOf e.name) (writeContents e.contents)} $dir/userdata/${e.name}
        '')
      cfg.settings
    # users
    + ''
      install -Dm444 ${json.generate "users_override.json" (mapAttrs (k: v: (user k v)) cfg.users.users)} $dir/userdata/users_override.json
    ''
    # remove trailing whitespace from all generated files. Ignore failure in case we have no generated files.
    + concatStringsSep "\n" (map
      (e: ''
        find $dir -type f -name '*.${e}' -print0 | xargs -0 sed -i 's/[ \t]*$//' || true
      '') [ "cfg" "config" "items" "persist" "things" ])
    );

  setupScript =
    let
      v2log = {
        "log4j2.rootLogger.level" = cfg.logging.logLevel;
        "log4j2.rootLogger.appenderRefs" = "stdout";
        "log4j2.rootLogger.appenderRef.stdout.ref" = "STDOUT";
        "log4j2.appender.console.layout.pattern" = "<%level{FATAL=2, ERROR=3, WARN=4, INFO=5, DEBUG=6, TRACE=7}>[%-36.36c] - %m%n";
      };

    in
    pkgs.resholve.writeScriptBin "openhab-setup"
      {
        interpreter = pkgs.runtimeShell;
        inputs = with pkgs; [ coreutils crudini findutils jq xmlstarlet ];
        execer = with pkgs; [
          "cannot:${getExe crudini}"
          # "cannot:${getExe xmlstarlet}"
        ];
      }
      (''
        set -eEuo pipefail

        DIST_DIR=${runEnv.OPENHAB_HOME}

        # Use this in case of problems with the generated configuration
        if [ ''${OPENHAB_SKIP_SETUP:-0} -eq 1 ]; then
          echo "Skipping setup as OPENHAB_SKIP_SETUP is set"
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
          if [ "${versionTag}" != "$(head -n1 ${versionMarker})" ]; then
            echo "Detected up- or downgrade"
            wipe_cache
          fi
        fi

        if [ -e "${heartbeatMarker}" ]; then
          echo "Cleaning stale heartbeat marker"
          rm ${heartbeatMarker}
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

        # karaf
        crudini --set $OPENHAB_USERDATA/etc/system.properties "" karaf.history ${libDir}/.karaf/karaf.history

      ''
      + optionalString cfg.users.enable ''
        file=$OPENHAB_USERDATA/jsondb/users.json
        if [ -e $file ]; then
          t=$(mktemp)
          cat $file ${libDir}/userdata/users_override.json | jq -s add > $t
          mv $t $file
        else
          install -Dm644 ${libDir}/userdata/users_override.json $file
        fi

      ''
      + optionalString (isV2 && cfg.logging.toStdout) ''
        file=$OPENHAB_USERDATA/etc/org.ops4j.pax.logging.cfg
        if [ -e $file ]; then
          ${concatStringsSep "\n" (mapAttrsToList (n: v: ''
            crudini --set $file "" "${n}" "${v}"
            '') v2log)}
        fi

      ''
      + optionalString (isV3 && cfg.logging.toStdout) ''
        file=$OPENHAB_USERDATA/etc/log4j2.xml

        if [ -e $file ]; then
          # http://xmlstar.sourceforge.net/doc/UG/ch04s03.html
          xml ed --inplace \
            --update "/Configuration/Appenders/Console/PatternLayout/@pattern" \
            -v '${cfg.logging.format}' \
            --update "/Configuration/Loggers/Root/@level" \
            -v '${cfg.logging.logLevel}' \
            --update "/Configuration/Loggers/Root/AppenderRef[@ref='LOGFILE']/@ref" \
            -v 'STDOUT' \
            $file
        fi
      ''
      + optionalString cfg.workarounds.delayRules.enable (
        concatStringsSep "\n" (mapAttrsToList
          (n: v: ''
            dir=${rulesTmpDir}/${n}
            test -e $dir || mkdir -p $dir
            for f in ${v}/*; do
              test -e "$f" || continue
              mv "$f" $dir/
            done
          '')
          rulesDirs)
      ));

  waitScript = port:
    let
      port' = toString port;

    in
    pkgs.writeShellApplication {
      name = "wait-for-openhab";
      runtimeInputs = with pkgs; [ coreutils gnugrep iproute ];
      text = ''
        if [ -d "$OPENHAB_USERDATA"/tmp/kar/openhab-addons-${cfg.package.version}/org/openhab/ui/bundles ]; then
          seconds=60
        else
          seconds=300
        fi

        timeout $seconds ${pkgs.runtimeShell} -c \
          'while ! ss -H -t -l -n sport = :${port'} | grep -q "^LISTEN.*:${port'}"; do sleep 1; done'
      '';
    };

  storeVersionScript = pkgs.resholve.writeScriptBin "openhab-store-version"
    {
      interpreter = pkgs.runtimeShell;
      inputs = with pkgs; [ coreutils ];
    }
    ''
      set -eEuo pipefail
      echo -n "${versionTag}" > ${versionMarker}
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
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
      <busconfig>
        <policy group="bluetooth">
          <allow own="org.bluez"/>
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
      </busconfig>
    '';
    destination = "/share/dbus-1/system.d/${name}";
  };

  runEnv = rec {
    JAVA = javaBin;
    JAVA_HOME = cfg.java.package.home;
    JAVA_OPTS = lib.concatStringsSep " " ([
      "-XshowSettings:vm"
      "-Xms${cfg.java.memoryMin}"
      "-Xmx${cfg.java.memoryMax}"
      "-XX:MaxMetaspaceSize=${cfg.java.metaMax}"
    ] ++ cfg.java.additionalArguments);

    # upstream's launcher script doesn't use exec unless running in daemon mode so force it
    # KARAF_EXEC = "exec";

    OPENHAB_CONF = "${libDir}/conf";
    OPENHAB_USERDATA = "${libDir}/userdata";
    OPENHAB_HOME = "${cfg.finalPackage}/share/openhab";
    OPENHAB_RUNTIME = "${OPENHAB_HOME}/runtime";
    OPENHAB_LOGDIR = "/var/log/openhab";
    OPENHAB_HTTP_PORT = toString cfg.ports.http;
    OPENHAB_HTTPS_PORT = toString cfg.ports.https;
  } // optionalAttrs cfg.debug {
    KARAF_DEBUG = 1;
  };

  openhabCli =
    let
      binDir = "${runEnv.OPENHAB_RUNTIME}/bin";
      # we do not want to allocate multiple GBs for the console
      runEnv' = lib.filterAttrs (n: _: n != "JAVA_OPTS") runEnv;

    in
    pkgs.resholve.writeScriptBin "openhab-cli"
      {
        interpreter = pkgs.runtimeShell;
        inputs = with pkgs; [ coreutils binDir systemd ];
        execer = [
          "cannot:${binDir}/client"
          "cannot:${getBin pkgs.systemd}/bin/systemctl"
        ];
      }
      ''
        set -eEuo pipefail

        _help() {
          echo "Usage: $(basename "$0") [command]"
          echo ""
          echo "Commands: "
          echo "  - client      : open the openHAB client"
          echo "  - clean-cache : clean cache on next restart"
          echo "  - info        : show info"
          echo "  - log         : show log"
          echo "  - reset       : reset the configuration fully on next restart"
          exit 1
        }

        export HOME=${libDir}
        ${concatStringsSep "\n" (mapAttrsToList (n: v: ''export ${n}="${toString v}"'') runEnv')}

        if [ -n "''${1:-}" ]; then
          cmd=$1
          shift
        else
          _help
        fi

        case $cmd in
          client|console)
            echo "Default password: habopen"
            client "$@"
            ;;
          clean-cache)
            echo "Cleaning cache on next restart"
            touch ${libDir}/.reset_cache
            ;;
          info)
            echo "openHAB: ${versionTag}"
            echo ""
            echo "Environment:"
            ${concatStringsSep "\n" (mapAttrsToList (n: v: ''echo " - ${n}=${toString v}"'') runEnv)}
            echo ""
            echo "Status: "
            systemctl status --lines 0 --no-pager openhab
            ;;
          log)
            journalctl -f -u openhab
            ;;
          reset)
            echo "Doing full reset on next restart"
            touch ${libDir}/.reset
            ;;
          -h|--help)
            _help
            ;;
          *)
            echo "Unknown command: $cmd"
            _help
            ;;
        esac
      '';


  delayRules = pkgs.resholve.writeScriptBin "openhab-delay-rules"
    {
      interpreter = pkgs.runtimeShell;
      inputs = with pkgs; [ coreutils ];
    }
    (
      ''
        sleep ${toString cfg.workarounds.delayRules.delay}
      ''
      + concatStringsSep "\n" (mapAttrsToList
        (n: v: ''
          dir=${v}
          test -e $dir || mkdir -p $dir
          for f in ${rulesTmpDir}/${n}/*; do
            test -e "$f" || continue
            mv "$f" $dir/
          done
        '')
        rulesDirs)
    );

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
          ++ optionals (cfg.withDefaultAddons && isV3dot4)
          (with packages; [ openhab34-addons ])
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
      # we need config here because we import helpers which requires it
      type = types.listOf (types.submodule (import ./items.nix { inherit config lib pkgs; }));
    };

    things = mkOption {
      default = [ ];
      description = "Things";
      type = types.listOf (types.submodule (import ./things.nix { inherit lib pkgs; }));
    };

    sitemaps = mkOption {
      default = { };
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
        default = if isV2 then pkgs.zulu8 else pkgs.openjdk17_headless;
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

      memoryMin = mkOption {
        description = "Initial memory to use.";
        type = types.str;
        default = "768m";
      };

      memoryMax = mkOption {
        description = "Maximum memory to use.";
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
      delayRules = {
        enable = mkOption {
          description = ''
            Work around rules loading too early. You probably want this enabled.
            The only downside is a slight delay after start before the rules
            will run. A similar workaround exists for openHABian.
          '';
          type = types.bool;
          default = true;
        };

        delay = mkOption {
          description = ''
            Delay before we load the rules. The default is completely arbitrary
            and depends on the speed of the computer on which you run openHAB as
            well as the number of bindings and things/items. If you have a fast
            machine, try lowering it and do the opposite in case of a slow device
            like an rpi.
          '';
          type = types.ints.positive;
          default = 60;
        };
      };

      lockDir = mkEnableOption "work around lock directory permissions";

      restart = {
        onDeploy = mkEnableOption "restarting openHAB when deploying new configurations as the load order is not deterministic";

        scheduled = {
          enable = mkEnableOption ''
            scheduled restart. You might want to enable this as openHAB
            v2 sometimes stops reading temperatures via MQTT and v3 will
            sometimes leak memory.
          '';

          restartAt = mkOption {
            description = "Time at which to restart. Choose a time when openHAB isn't doing anything";
            type = types.str;
            default = "*-*-* 05:00:00";
          };
        };
      };
    };

    cloud = {
      enable = mkOption {
        description = lib.mdDoc "Enable cloud monitoring";
        type = types.bool;
        default = cfg.cloud.user != null && cfg.cloud.pass != null;
        readOnly = true;
      };

      user = mkOption {
        description = lib.mdDoc "User";
        type = with types; nullOr (either string path);
        default = null;
      };

      pass = mkOption {
        description = lib.mdDoc "Password";
        type = with types; nullOr (either string path);
        default = null;
      };

      item = mkOption {
        description = lib.mdDoc "Item for heartbeat monitoring";
        type = types.str;
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf cfg.debug {
      services.openhab.logging.logLevel = mkForce "DEBUG";
    })

    {
      environment.systemPackages = [
        openhabCli
        # TODO: move this out of toupstream
        (pkgs.resholve.writeScriptBin "copy-openhab-config"
          {
            interpreter = pkgs.runtimeShell;
            inputs = with pkgs; [ coreutils config.programs.git.package ];
            execer = [ "cannot:${getExe config.programs.git.package}" ];
          }
          ''
            set -eEuo pipefail

            SRC=/etc/openhab
            TGT=''${1:-''${XDG_STATE_HOME:-$HOME/.local/state}/openhab}

            if [ ! -e "$SRC" ]; then
              echo "openHAB config not found in $SRC. Aborting!"
              exit 1
            fi

            test -e "$TGT" || mkdir -p "$TGT"

            pushd "$TGT"
            FIRST_RUN=0
            if [ ! -d .git ]; then
              git init --object-format=sha256
              FIRST_RUN=1
            fi
            rm -rf conf userdata
            cp --no-preserve=all -r "$SRC"/* "$TGT/"

            mkdir -p userdata/tmp/instances
            cat >userdata/tmp/instances/instance.properties <<_EOF
            count = 1
            item.0.name = openhab
            item.0.loc = /home/peter/.local/state/openhab/userdata
            item.0.pid = 779086
            item.0.root = true
            _EOF

            if [ "$FIRST_RUN" -eq 1 ]; then
              git add .
              git commit -m 'initial commit'
            fi
          '')
      ];

      services.openhab = {
        items = lib.flatten
          (map
            (e: (import e { inherit config lib pkgs; }).items)
            cfg.itemThingFiles)
        ++ optionals cfg.cloud.enable [
          {
            name = cfg.cloud.item;
            label = "Cloud Heartbeat";
            type = "DateTime";
            file = "_generated";
          }
        ];

        things = lib.flatten
          (map
            (e: (import e { inherit config lib pkgs; }).things)
            cfg.itemThingFiles);
      };
    }

    (mkIf cfg.configOnly {
      environment = {
        etc."openhab".source = "${cfgDrv}/etc/openhab";
        # we don't want to pull in java and all the other stuff
        # systemPackages = [ openhabCli ];
      };
    })

    (mkIf (!cfg.configOnly) {
      hardware.bluetooth = mkIf cfg.bluetooth.enable {
        inherit (cfg.bluetooth) enable;
        # package = pkgs.bluezFull;
        powerOnBoot = true;
        # https://github.com/Vudentz/BlueZ/blob/master/src/main.conf
        settings = {
          General = {
            ControllerMode = "dual"; # dual bredr le  - now we have LE support
            FastConnectable = true;
          };
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

      services.dbus = mkIf cfg.bluetooth.enable {
        packages = [ bluetoothDbus ];
      };

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
        # ++ optionals (!cfg.zigbee.enable) [ ''ENV{SYSTEMD_WANTS}="zigbee2mqtt.service"'' ]
        # );
      };

      systemd = {
        paths.openhab-restart = {
          description = "Restart openHAB";
          wantedBy = [ "paths.target" ];
          pathConfig = {
            PathExists = restartMarker;
            Unit = "openhab-restart.service";
            TriggerLimitIntervalSec = "10s";
          };
        };

        services =
          let
            documentation = [
              "https://www.openhab.org/docs/"
              "https://community.openhab.org"
            ];

            environment = runEnv;

            wantedBy = [ "openhab.target" ];

            commonServiceConfig = attrs:
              recursiveUpdate
                {
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
                  # RestrictAddressFamilies = [
                  #   "AF_UNIX"
                  #   "AF_INET"
                  #   "AF_INET6"
                  #   "AF_NETLINK"
                  #   "AF_PACKET"
                  # ]
                  # ++ optionals cfg.bluetooth.enable [ "AF_PACKET" ];
                  RestrictRealtime = true;
                  RestrictSUIDSGID = true;
                  SystemCallArchitectures = "native";
                  CacheDirectory = dirName;
                  StateDirectory = dirName;
                  WorkingDirectory = libDir;
                  # TODO: move keys somewhere else
                  SupplementaryGroups = [
                    "openhab-tokens"
                  ]
                  ++ optionals cfg.bluetooth.enable [
                    "bluetooth"
                  ];
                  Slice = "openhab.slice";
                  InaccessiblePaths = [
                    "-/var/lib/containers"
                  ];
                }
                attrs;

          in
          {
            openhab-tokens = rec {
              description = "openHAB - copy in tokens";
              inherit documentation environment wantedBy;
              after = [ "openhab-setup.service" ];
              wants = after;
              unitConfig.ConditionPathExists = privateDir;
              serviceConfig = commonServiceConfig {
                Type = "oneshot";
                PrivateDevices = true;
                PrivateNetwork = true;
                ExecStart =
                  let
                    script = ''
                      set -eEuo pipefail

                      FIRST_RUN=${libDir}/.first_run

                      _copy() {
                        source="$1"
                        target="$2"

                        install --preserve-timestamps -Dm666 "$source" "$target"
                      }

                      _conditional_copy() {
                        source="${privateDir}/$1"
                        target="${libDir}/$2/$1"

                        if [ -e $FIRST_RUN ]; then
                          _copy "$source" "$target"
                        elif [ ! -e "$target" ]; then
                          _copy "$source" "$target"
                        fi
                      }
                    ''
                    + concatMapStringsSep "\n" (e: ''_conditional_copy "${e.name}" "${e.path}"'') cfg.keyFiles
                    + ''

                      rm -f $FIRST_RUN
                    '';

                  in
                  getExe (pkgs.resholve.writeScriptBin "openhab-tokens"
                    {
                      interpreter = pkgs.runtimeShell;
                      inputs = with pkgs; [ coreutils ];
                    }
                    script);
              };
            };

            openhab-setup = {
              description = "openHAB - copy and link config files into place";
              inherit documentation environment wantedBy;
              restartTriggers = [ cfgDrv ];
              serviceConfig = commonServiceConfig {
                Type = "oneshot";
                ExecStart = getExe setupScript;
                PrivateDevices = true;
                PrivateNetwork = true;
              };
            };

            openhab = rec {
              description = "openHAB ${toString cfg.package.version}";
              inherit documentation environment wantedBy;
              wants = [ "network-online.target" "nss-lookup.target" "openhab-setup.service" ];
              after = wants;
              path = [
                "/run/wrappers"
                cfg.java.package
                pkgs.ffmpeg
                pkgs.ncurses # needed by the infocmp program
              ];
              restartTriggers = [
              ]
              # we do NOT need to restart with OH 3 as it will pick up changed files
              ++ optionals (isV2 || cfg.workarounds.restart.onDeploy) [
                cfgDrv
                (getExe setupScript)
              ];

              serviceConfig = commonServiceConfig
                {
                  Type =
                    if (lib.versionAtLeast pkgs.systemd.version "240")
                    then "exec"
                    else "simple";
                  SupplementaryGroups = (commonServiceConfig { }).SupplementaryGroups ++ [
                    "audio"
                    "dialout"
                    "tty"
                  ]
                    ++ optionals cfg.workarounds.lockDir [ "uucp" ]; # needed for /run/lock with zigbee
                  AmbientCapabilities = [
                    # TODO: find out why it fails without all capabilities
                    "~"
                    # "CAP_NET_ADMIN"
                    # "CAP_NET_BIND_SERVICE"
                    # "CAP_NET_RAW"
                  ];
                  ExecStartPre = optionals cfg.bluetooth.enable [
                    (lib.getExe (pkgs.resholve.writeScriptBin "toggle-bluetooth"
                      {
                        interpreter = lib.getExe pkgs.bash;
                        inputs = with pkgs; [ coreutils config.hardware.bluetooth.package ];
                      }
                      ''
                        DEV=hci0

                        sleep 10
                        hciconfig $DEV down
                        sleep 10
                        hciconfig $DEV up
                      ''))
                  ];

                  ExecStart = concatStringsSep " " ([
                    "${cfg.finalPackage}/bin/openhab"
                    "run"
                  ]
                  ++ optionals cfg.debug [ "-v -l 4" ]
                  );
                  ExecStartPost = map getExe ([
                    (waitScript cfg.ports.http)
                    storeVersionScript
                  ] ++ optionals cfg.workarounds.delayRules.enable [
                    delayRules
                  ]);
                  ExecStop = "${cfg.finalPackage}/bin/openhab stop";
                  ExecStopPost = "${pkgs.coreutils}/bin/rm -f ${restartMarker}";
                  SuccessExitStatus = "0 143";
                  RestartSec = "5s";
                  Restart = "on-failure";
                  TimeoutStartSec =
                    let
                      dcfg = cfg.workarounds.delayRules;
                      s = 180 + (if dcfg.enable then dcfg.delay else 0);
                    in
                    "${toString s}s";
                  TimeoutStopSec = "120s";
                  LimitNOFILE = 102642;
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

            openhab-restart =
              let
                cfg' = cfg.workarounds.restart.scheduled;
              in
              {
                description = "Restart openHAB";
                reloadIfChanged = true;
                restartIfChanged = false;
                startAt = mkIf cfg'.enable cfg'.restartAt;
                serviceConfig = {
                  Type = "oneshot";
                  PrivateNetwork = true;
                  PrivateTmp = true;
                  ExecStart = getExe (pkgs.resholve.writeScriptBin "openhab-restart"
                    {
                      interpreter = pkgs.runtimeShell;
                      inputs = with pkgs; [ coreutils systemd ];
                      execer = [ "cannot:${getBin pkgs.systemd}/bin/systemctl" ];
                    }
                    ''
                      rm -f ${restartMarker}
                      systemctl restart openhab.service
                    '');
                };
              };

            openhab-heartbeat = mkIf cfg.cloud.enable {
              description = "Heartbeat check for myopenhab.org";
              serviceConfig = commonServiceConfig rec {
                Type = "oneshot";
                ExecCondition = [
                  "${getBin pkgs.systemd}/bin/systemctl is-active --quiet openhab.service"
                ];
                ExecStart = concatStringsSep " " [
                  "${getExe pkgs.openhab.openhab-heartbeat}"
                  "--minutes 5"
                  "--item ${cfg.cloud.item}"
                  "--heartbeat ${heartbeatMarker}"
                  "--log %L/${LogsDirectory}/heartbeat.log"
                  "--file ${restartMarker}"
                  "--user %d/user"
                  "--pass %d/pass"
                  # "--verbose"
                ];
                LoadCredential = [
                  "user:${cfg.cloud.user}"
                  "pass:${cfg.cloud.pass}"
                ];
                LogsDirectory = "openhab";
                SyslogIdentifier = "%N";
                TimeoutSec = "20s";
              };
              startAt = "minutely";
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
        openhab-tokens = { };
      };
    })
  ]);
}
