{ config, lib, pkgs, ... }:

let
  inherit (builtins)
    attrNames isAttrs isBool isList isString length;

  inherit (lib)
    boolToString concatMapStringsSep concatStringsSep replaceStrings
    mapAttrsToList
    filter flatten
    toLower
    optional optionals optionalAttrs optionalString singleton;

  cfg = config.services.openhab;

  has = listOrAttrs:
    if (isAttrs listOrAttrs)
    then (length (compact (builtins.attrNames (listOrAttrs)))) > 0
    else if (isList listOrAttrs)
    then (length (compact listOrAttrs)) > 0
    else listOrAttrs != "";

  compact = list:
    if builtins.isList list
    then filter (e: (e != null) && (e != "")) list
    else compact [ list ];

  listToText = list:
    concatStringsSep " " list;

  attrsToText = quote: attrs:
    let
      sep = if (length (attrNames attrs) > 1) then "\n" else " ";
    in
    concatStringsSep (if quote then ", ${sep}" else sep)
      (lib.mapAttrsToList
        (k: v:
          let
            # this is to quote any JSON we may be passing in the value for mqtt transfmrmations
            val =
              if (builtins.isString v) && quote
              then replaceStrings [ "\"" ] [ "\\\"" ] v
              else v;

          in
          "${optionalString quote "  "}${k}=${if quote then toQuotedText val else toPlainText v}")
        attrs);

  attrsToPlainText = attrsToText false;

  attrsToQuotedText = attrsToText true;

  toText = quote: value:
    if isList value
    then concatStringsSep "," value
    else if isBool value
    then boolToString value
    else if isString value
    then if quote then ''"${value}"'' else value
    else toString value;

  toPlainText = toText false;

  toQuotedText = toText true;

  wrap = str:
    ''"'' + toString str + ''"'';

in
rec {
  attrsToChannel = t: ''
    Channels:
  ''
  + (lib.concatMapStringsSep "\n"
    (e: listToText ([ "Type" e.subtype ":" e.id ]
      ++ optional (e.label != null) (wrap e.label)
      ++ optional (has e.params) (
      let
        sep = if (length (attrNames e.params) > 1) then "\n" else " ";
      in
      ("[" + sep + (attrsToQuotedText e.params) + sep + "]")
    )
    ))
    t.channels)
  ;

  # itemtype itemname "labeltext [stateformat]" <iconname> (group1, group2, ...) ["tag1", "tag2", ...] {bindingconfig}
  # examples:
  #   Switch Kitchen_Light "Kitchen Light" mappings=[FOO="ON", BAR="OFF"] {channel="mqtt:topic:..." }
  #   Number Livingroom_Temperature "Temperature [%.1f °C]" <temperature> (gTemperature, gLivingroom) ["TargetTemperature"] {knx="1/0/15+0/0/15"}
  attrsToItem = i:
    let
      finalSettings = { }
        // optionalAttrs (has i.settings) i.settings
        // optionalAttrs (has i.influxdb.key) { influxdb = i.influxdb.key; };

      hasInfluxTags = (has i.influxdb.key) && (has i.influxdb.tags);
      hasSubAttrs = (has i.subAttrs);

    in
    listToText (
      (if i.type == "Group"
      then [ (concatStringsSep ":" (compact [ i.type i.subtype i.aggregate ])) i.name ]
      else [ i.type i.name ])
      ++ optional (i.label != null)
        (wrap i.label)
      ++ optional (i.icon != null)
        "<${i.icon}>"
      ++ optional (has i.groups)
        ("(" + concatStringsSep ", " i.groups + ")")
      ++ optional (has i.tags)
        ("[" + concatStringsSep ", " (map wrap i.tags) + "]")
      ++ optional (has finalSettings) (
        let
          sep = if (length (attrNames i.settings) > 1) then "\n" else " ";
        in
        "{${sep}"
        + (attrsToQuotedText finalSettings)
        + (optionalString hasInfluxTags (
          " [ "
          + (attrsToQuotedText i.influxdb.tags)
          # + (attrsToQuotedText i.subAttrs)
          + " ] "
        ))
        + "${sep}}"
      )
      ++ [ i.extraConfig ]
    );

  # Thing <binding_id>:<type_id>:<thing_id> " Label " @ " Location " [ <parameters> ]
  # example: Thing network:device:webcam " Webcam " @ " Living Room " [ hostname="192.168.0.2", timeout="5000", ... ]
  attrsToThing = t:
    listToText
      (lib.flatten
        (
          [ t.type ]
          ++ singleton (thingId t)
          ++ optional (t.label != null) (wrap t.label)
          ++ optional (t.bridge != null) "(${bridgeName [ t.binding t.bridge ]})"
          ++ optional (t.location != null) ''@ ${wrap t.location}''
          ++ optional (has t.params) (
            let
              sep = if (length (attrNames t.params) > 1) then "\n" else " ";
            in
            ("[${sep}" + (attrsToQuotedText t.params) + "${sep}]")
          )
          ++ optional (has t.things || has t.channels) "{\n"
          # ++ optional (has t.things) (lib.concatStringsSep "\n" (map attrsToThing (map (e: makeChild t e) t.things)))
          ++ optional (has t.things) ("\n" + (lib.concatStringsSep "\n" (lib.flatten (map attrsToThing t.things))) + "\n")
          ++ optional (has t.channels) (attrsToChannel t)
          ++ optional (has t.things || has t.channels) "}\n"
        )
      );

  attrsToFile = attrs: name:
    pkgs.writeText "openhab-${name}" (attrsToQuotedText attrs);

  attrsToPlainFile = attrs: name:
    pkgs.writeText "openhab-${name}" (attrsToPlainText attrs);

  attrsToConfig = attrs:
    ":org.apache.felix.configadmin.revision:=L\"2\"\n"
    + lib.concatStringsSep "\n" (lib.mapAttrsToList (key: val: "${key}=${wrap val}") attrs);

  attrsToSitemap = name: smap:
    ''
      sitemap ${name} label="${smap.label}" {
        ${smap.content}
      }
    '';

  inherit
    attrsToPlainText attrsToQuotedText
    toPlainText toQuotedText;

  itemFileName = item:
    lib.toLower (lib.concatStringsSep "_" [ item.name ]) + ".items";

  thingFileName = thing:
    lib.toLower (lib.concatStringsSep "_" (compact (with thing; [ binding id ]))) + ".things";

  thingName = listOrStr:
    if builtins.isList listOrStr
    # a MAC will contain : but that needs to be replaced first
    then thingName (concatStringsSep ":" (map (e: replaceStrings [ ":" ] [ "_" ] e) listOrStr))
    else replaceWithChar [ " " ] "_" listOrStr;

  bridgeName = listOrStr:
    if builtins.isList listOrStr
    then concatMapStringsSep ":" bridgeName listOrStr
    else replaceWithChar [ " " ] "_" listOrStr;

  channelName = thingName;

  topicName = list:
    concatStringsSep "/" (map (e: replaceWithChar [ " " ] "_" (toLower e)) list);

  replaceWithChar = needle: char: haystack:
    replaceStrings needle (lib.genList (_: char) (builtins.length needle)) haystack;

  sanitizeItemName = listOrStr:
    let
      sep = "_";
    in
    if builtins.isList listOrStr
    then sanitizeItemName (concatStringsSep sep (map sanitizeItemName listOrStr))
    # this is ugly, I know
    else
      replaceWithChar [ "____" "___" "__" ] sep
        (replaceWithChar [ ":" "-" "," "(" ")" "'" " " ] sep
          (toString listOrStr));

  itemName = listOrStr:
    toLower (sanitizeItemName listOrStr);

  siteMapThingName = listOrStr:
    if builtins.isList listOrStr
    then siteMapThingName (concatStringsSep ":" listOrStr)
    else toLower (replaceStrings [ " " ] [ "_" ] listOrStr);

  # things are case sensitive, so we cannot toLower it
  thingId = thing:
    if thing.nested
    then (concatStringsSep " " (compact [ thing.subtype thing.id ]))
    else (concatStringsSep ":" (compact [ thing.binding thing.subtype thing.id ]));

  thingToItem = thing:
    entityName (concatStringsSep "_" (lib.splitString ":" thing));

  entityName = name:
    replaceStrings [ ":" ] [ "_" ] name;

  macToName =
    entityName;

  jarAddon = { name, version, src }: pkgs.stdenv.mkDerivation rec {
    pname = "openhab-addon-${name}";
    inherit version src;
    nativeBuildInputs = with pkgs; [ unzip ];
    buildCommand = ''
      dir=$out/share/openhab/addons
      mkdir -p $dir

      ${if lib.hasSuffix "zip" src.name
        then "unzip -q ${src} -d $dir/"
        else "install -Dm444 ${src} $dir/${src.name}"}
    '';
  };

  keyPrefix = {
    _2 = "org.eclipse.smarthome";
    _3 = "org.openhab";
  }."_${lib.versions.major cfg.package.version}";

  # the functions under versions return a string
  isVX = version:
    (lib.versions.major cfg.package.version) == (toString version);
  isVXY = version:
    (lib.versions.majorMinor cfg.package.version) == version;
  isV2 = isVX 2;
  isV2dot5 = isVXY "2.5";
  isV3 = isVX 3;
  isV3dot1 = isVXY "3.1";
  isV3dot2 = isVXY "3.2";
  isV3dot3 = isVXY "3.3";
  isV3dot4 = isVXY "3.4";
  isV4 = isVX 4;

  wrapBinary = binary: addons:
    pkgs.symlinkJoin {
      name = "openhab-wrapped-${binary.version}";
      paths = [ binary ] ++ addons;
      nativeBuildInputs = with pkgs; [ makeWrapper ];
      postBuild = ''
        dir=$out/share/openhab

        makeWrapper $dir/runtime/bin/karaf $out/bin/openhab \
          --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath (with pkgs; [ bluez udev ])} \
          --prefix PATH : ${lib.makeBinPath (with pkgs; [ "/run/wrappers" gawk procps ])}
      '';
    };

  mergeChildren = attrs: list:
    # we flatten here to avoid having to deal with it in nested mergeChildren
    # invocations which becomes super annoying
    map (e: lib.recursiveUpdate attrs e) (flatten list);

}
