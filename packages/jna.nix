{ stdenv, lib, fetchFromGitHub }:

# this is currently not used as openhab vendors it

stdenv.mkDerivation (finalAttrs: {
  pname = "java-jna";
  version = "5.14.0";

  src = fetchFromGitHub {
    owner = "java-native-access";
    repo = "jna";
    rev = finalAttrs.version;
    hash = "sha256-a5l9khKLWfvTHv53utfbw344/UNQOnIU93+wZNQ0ji4=";
  };

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    mv dist/{jna,linux}*.jar $out

    runHook postInstall
  '';

  meta = with lib; {
    description = "Java Native Access";
    license = licenses.free;
    maintainers = with maintainers; [ peterhoeg ];
    platforms = platforms.linux;
  };
})
