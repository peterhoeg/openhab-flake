{
  stdenvNoCC,
  lib,
  fetchFromGitHub,
  fetchFromGitLab,
  fetchurl,
  nodejs,
  buildNpmPackage,
  makeWrapper,
  nix-update-script,
  python3,
  crystal,
  openssl,
  zlib,
  cloudHomeDir ? "/var/lib/openhabcloud",
}:

let
  urls =
    {
      pname,
      version,
      ext,
    }:
    let
      path = "org/openhab/distro/${pname}/${version}/${pname}-${version}.${ext}";
    in
    [
      "https://openhab.jfrog.io/artifactory/libs-release-local/${path}"
      "https://openhab.jfrog.io/artifactory/libs-milestone-local/${path}"
      "https://bintray.com/openhab/mvn/download_file?file_path=${path}"
      "https://repo1.maven.org/maven2/${path}"
    ];

  addon =
    {
      pname ? "openhab-addons",
      version,
      hash,
    }:
    stdenvNoCC.mkDerivation (finalAttrs: {
      inherit pname version;

      src = fetchurl {
        urls = urls {
          inherit pname version;
          ext = "kar";
        };
        inherit hash;
      };

      buildCommand = ''
        install -Dm444 $src $out/share/openhab/addons/${finalAttrs.finalPackage.src.name}
      '';
    });

  generic =
    { version, hash }:
    stdenvNoCC.mkDerivation rec {
      pname = "openhab";
      inherit version;

      src = fetchurl {
        urls = urls {
          inherit pname version;
          ext = "tar.gz";
        };
        inherit hash;
      };

      sourceRoot = ".";

      dontConfigure = true;

      dontBuild = true;

      postPatch = ''
        dir=runtime/bin

        rm $dir/*.{bat,lst,ps1,psm1}

        for file in oh2_dir_layout oh_dir_layout; do
          if [ -e  $dir/$file ]; then
            sed -i $dir/$file \
              -e '/export OPENHAB_HOME/d'
          fi
        done
      '';

      installPhase = ''
        runHook preInstall

        base=$out/share/openhab

        mkdir -p $base
        cp -r * $base/

        find $base -name '*jna*.jar' -exec ln -s '{}' $base/runtime/lib/boot \;

        runHook postInstall
      '';

      meta = with lib; {
        description = "OpenHAB - vendor and technology agnostic open source home automation software";
        homepage = "https://www.openhab.org";
        license = licenses.epl10;
        maintainers = with maintainers; [ peterhoeg ];
      };
    };

in
rec {
  openhab-cloud = buildNpmPackage rec {
    pname = "openhab-cloud";
    version = "1.0.16";

    src = fetchFromGitHub {
      owner = "openhab";
      repo = pname;
      rev = "v" + version;
      hash = "sha256-Oe7U0h0ym9KYOtqJTKA35nnqZob+iL8J7UcJV2K7YRQ=";
    };

    postPatch = ''
      find . -name '*.js' -exec \
        sed -i -e "s@require('./config.json')@require('${cloudHomeDir}/config.json')@" {} \;
    '';

    npmDepsHash = "sha256-FIxbwN4Pw9E1thzr8ADi3fhEnlon+Ol7TIBFlQpgcCo=";

    nativeBuildInputs = [
      makeWrapper
      python3
    ];

    dontNpmBuild = true;

    postInstall = ''
      mkdir -p $out/bin

      makeWrapper ${lib.getExe nodejs} $out/bin/openhabcloud \
        --argv0 openhabcloud \
        --chdir ${cloudHomeDir} \
        --set NODE_PATH "$out/lib/node_modules" \
        --add-flags $out/lib/node_modules/openhabcloud/app.js
    '';

    passthru = {
      homeDir = cloudHomeDir;
      updateScript = nix-update-script { };
    };

    meta = with lib; {
      description = "openHAB cloud component";
      homepage = "https://openhab.org";
      license = licenses.epl10;
      maintainers = with maintainers; [ peterhoeg ];
      platforms = platforms.unix;
    };
  };

  openhab2 = generic {
    version = "2.5.12";
    hash = "sha256-JOinHmvCIwOAAWOHHRwFVIQ/oZ6c1zbmvnIaoHmLvjo=";
  };

  openhab2-v1-addons = addon {
    pname = "openhab-addons-legacy";
    hash = "sha256-5yDC6L+azep6UOa9FOM8trSxffsAVqdusVQRGF74X3w=";
    inherit (openhab2) version;
  };

  openhab2-v2-addons = addon {
    hash = "sha256-ZUSjI68R9Xfd5zb2lCxYM4edC0F3BwD8xmehiHVcbM4=";
    inherit (openhab2) version;
  };

  # V3+ has no legacy addons

  openhab31 = generic {
    version = "3.1.1";
    hash = "sha256-nPv3mtciDQVT/BWvIiX8JZfxlVJDX/QbIXLDsUv8RDA=";
  };

  openhab31-addons = addon {
    hash = "sha256-5c9a3MnHJBnTY69Rpkg+TvpxHgwHGmoOz/UoV7/pqPo=";
    inherit (openhab31) version;
  };

  openhab32 = generic {
    version = "3.2.0";
    hash = "sha256-6Bha3Kq97EuGDCLshU832wqkkNR+P4ZUzvDx3XNG1HY=";
  };

  openhab32-addons = addon {
    hash = "sha256-VD07+m3Okh+5/PuXEFhG2kqi1crNrWvpEKNAxcMAB6w=";
    inherit (openhab32) version;
  };

  openhab33 = generic {
    version = "3.3.0";
    hash = "sha256-nq8Jjfu3nxAsnKgxNVlCJNGbozrDEZTvJ4ERYgRDeGs=";
  };

  openhab33-addons = addon {
    hash = "sha256-tUH5+/0XrNsK4AZPdTphTLGowK7NJW0aX3rBCPfssD4=";
    inherit (openhab33) version;
  };

  openhab34 = generic {
    version = "3.4.5";
    hash = "sha256-BRiC5LqoPVq0vJ4e3rFwx9VHTEQj3JZa2x+Ak0vz10s=";
  };

  openhab34-addons = addon {
    hash = "sha256-Rr9G4aA8Le51Vcyewl020kiF2CO09b++TLeESvDtZ90=";
    inherit (openhab34) version;
  };

  openhab40 = generic {
    version = "4.0.4";
    hash = "sha256-ce/9n9uOZO5Io64wyPQTKhHIFF6D78VptxBJZ9WmDIs=";
  };

  openhab40-addons = addon {
    hash = "sha256-z1txN3nN5CMNM5BCA8YL8fynyKIcrX1OQWt5SbIgBVo=";
    inherit (openhab40) version;
  };

  openhab41 = generic {
    version = "4.1.3";
    hash = "sha256-CGzmEYSutFNG5jYX8RptJZNkXEnHGlk1fOXZzc6cNIQ=";
  };

  openhab41-addons = addon {
    hash = "sha256-M15OZBwJ/LqTTZSSiWjtb9kCApFi4E1qQndJG8RUttA=";
    inherit (openhab41) version;
  };

  openhab42 = generic {
    version = "4.2.3";
    hash = "sha256-6v3+3dCn2uPQZXIOOGx1ZlkDGBYMtbQ03S0Ji3oP7dY=";
  };

  openhab42-addons = addon {
    hash = "sha256-ndbIaZcKbuOW3Y0Ypno4ckSRIv25pCSzvhc6zirLRTY=";
    inherit (openhab42) version;
  };

  openhab43 = generic {
    version = "4.3.6";
    hash = "sha256-hXm0kHvUsqpkNSkoCOIOqfK+7cTYrAFnw4DbIVqTKfI=";
  };

  openhab43-addons = addon {
    hash = "sha256-v87qvrTY1xLLKlMJEiXntt5YKbAaLoQsKEfDSbO+nRM=";
    inherit (openhab43) version;
  };

  openhab50 = generic {
    version = "5.0.0";
    hash = "sha256-bRtKBhf4A49X0X8W01h991udOQJE3ahB2dj/Zf5IyOk=";
  };

  openhab50-addons = addon {
    hash = "sha256-dyyUU8TeyT1DVa4LdXaeswu/t/W9YGOhiVMUqUh6kqM=";
    inherit (openhab50) version;
  };

  openhab-stable = openhab43;
  openhab-stable-addons = openhab43-addons;

  openhab-heartbeat = crystal.buildCrystalPackage rec {
    pname = "openhab-heartbeat";
    version = "0.1.4";

    format = "shards";
    shardsFile = ./shards.nix;

    src = fetchFromGitLab {
      owner = "peterhoeg";
      repo = "openhab-heartbeat";
      rev = "v" + version;
      hash = "sha256-fW8/Pi5b6cY/gx6kov/TViRsF8A3MB/WRNgrTIecl5U=";
    };

    buildInputs = [
      openssl
      zlib
    ];

    doCheck = false;

    postFixup = ''
      strip $out/bin/*
    '';

    meta = with lib; {
      description = "openHAB Cloud Connector heartbeat";
      license = licenses.gpl3Only;
      maintainers = with maintainers; [ peterhoeg ];
      mainProgram = "heartbeat";
    };
  };
}
