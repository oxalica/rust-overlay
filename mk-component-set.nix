# Define component derivations and special treatments.
{ lib, stdenv, gnutar, autoPatchelfHook, zlib
, toRustTarget, removeNulls
}:
# Release version of the whole set.
{ version
# The host platform of this set.
, platform
# Set of pname -> src
, srcs
# { clippy.to = "clippy-preview"; }
, renames
}:
let
  inherit (lib) elem mapAttrs optional optionalString makeLibraryPath;
  inherit (stdenv) hostPlatform targetPlatform;

  mkComponent = pname: src:
    stdenv.mkDerivation rec {
      inherit pname version src;
      name = "${pname}-${version}-${platform}";

      passthru.platform = platform;

      # No point copying src to a build server, then copying back the
      # entire unpacked contents after just a little twiddling.
      preferLocalBuild = true;

      nativeBuildInputs = [ gnutar ] ++ optional (!dontFixup) autoPatchelfHook;
      buildInputs =
        optional (elem pname [ "rustc" "cargo" "llvm-tools-preview" ]) zlib ++
        # These components link to `librustc_driver*.so` or `libLLVM*.so`.
        optional (elem pname [ "clippy-preview" "rls-preview" "miri-preview" "rustc-dev" ]) self.rustc;

      dontConfigure = true;
      dontBuild = true;

      installPhase = ''
        runHook preInstall
        installerVersion=$(< ./rust-installer-version)
        if [[ "$installerVersion" != 3 ]]; then
          echo "Unknown installer version: $installerVersion"
        fi
        mkdir -p "$out"
        while read -r comp; do
          echo "Installing component $comp"
          # We don't want to parse the file and invoking cp in bash due to slow forking.
          cut -d: -f2 <"$comp/manifest.in" | tar -cf - -C "$comp" --files-from - | tar -xC "$out"
        done <./components
        runHook postInstall
      '';

      postInstall = ''
        # Function moves well-known files from etc/
        handleEtc() {
          if [[ -d "$1" ]]; then
            mkdir -p "$(dirname "$2")"
            mv -T "$1" "$2"
          fi
        }
        if [[ -e "$out/etc" ]]; then
          handleEtc "$out/etc/bash_completion.d" "$out/share/bash-completion/completions"
          rmdir $out/etc || { echo "Installer tries to install to /etc: $(ls $out/etc)"; exit 1; }
        fi
      '';

      # Only contain tons of html files. Don't waste time scanning files.
      dontFixup = elem pname [ "rust-docs" "rustc-docs" ];

      dontStrip = true;
    };

  self = mapAttrs mkComponent srcs;

in
  removeNulls (
    self //
    mapAttrs (alias: { to }: self.${to} or null) renames)
