# Define component derivations and special treatments.
{ lib, stdenv, stdenvNoCC, gnutar, autoPatchelfHook, bintools, zlib, gccForLibs
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
  inherit (lib) elem mapAttrs optional optionalString;
  inherit (stdenv) hostPlatform;

  mkComponent = pname: src: let
    # These components link to `librustc_driver*.so` or `libLLVM*.so`.
    linksToRustc = elem pname [
      "clippy-preview"
      "miri-preview"
      "rls-preview"
      "rust-analyzer-preview"
      "rustc-codegen-cranelift-preview"
      "rustc-dev"
      "rustfmt-preview"
    ];
  in
    stdenvNoCC.mkDerivation rec {
      inherit pname version src;
      name = "${pname}-${version}-${platform}";

      passthru.platform = platform;

      # No point copying src to a build server, then copying back the
      # entire unpacked contents after just a little twiddling.
      preferLocalBuild = true;

      nativeBuildInputs = [ gnutar ] ++
        # Darwin doesn't use ELF, and they usually just work due to relative RPATH.
        optional (!dontFixup && !hostPlatform.isDarwin) autoPatchelfHook ++
        # For `install_name_tool`.
        optional (hostPlatform.isDarwin && linksToRustc) bintools;

      buildInputs =
        optional (elem pname [ "rustc" "cargo" "llvm-tools-preview" "rust" ]) zlib ++
        optional linksToRustc self.rustc;

      # Most of binaries links to `libgcc.so` on Linux, which lives in `gccForLibs.libgcc`
      # since https://github.com/NixOS/nixpkgs/pull/209870
      # See https://github.com/oxalica/rust-overlay/issues/121
      #
      # Nightly `rustc` since 2022-02-17 links to `libstdc++.so.6` on Linux,
      # which lives in `gccForLibs.lib`.
      # https://github.com/oxalica/rust-overlay/issues/73
      # See https://github.com/oxalica/rust-overlay/issues/73
      #
      # FIXME: `libstdc++.so` is not necessary now. Figure out the time point
      # of it so we can use `gccForLibs.libgcc` instead.
      #
      # N.B. `gcc` is a compiler which is sensitive to `targetPlatform`.
      # We use `depsHostHost` instead of `buildInputs` to force it ignore the target,
      # since binaries produced by `rustc` don't actually relies on this gccForLibs.
      depsHostHost =
        optional (!dontFixup && !hostPlatform.isDarwin) gccForLibs.lib;

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

      # Darwin binaries usually just work... except for these linking to rustc from another drv.
      postFixup = optionalString (hostPlatform.isDarwin && linksToRustc) ''
        for f in $out/bin/*; do
          install_name_tool -add_rpath "${self.rustc}/lib" "$f" || true
        done
      '';

      dontStrip = true;
    };

  self = mapAttrs mkComponent srcs;

in
  removeNulls (
    self //
    mapAttrs (alias: { to }: self.${to} or null) renames)
