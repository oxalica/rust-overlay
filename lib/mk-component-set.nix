# Define component derivations and special treatments.
{ lib, stdenv, stdenvNoCC, gnutar, autoPatchelfHook, bintools, zlib, gccForLibs
, apple-sdk ? null
, pkgsHostHost
# The path to nixpkgs root.
, path
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
  inherit (stdenv) hostPlatform targetPlatform;

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
      ''
      # Wrap the shipped `rust-lld` (lld), which is used by default on some targets.
      # Unfortunately there is no hook to conveniently wrap CC tools inside
      # derivation and `wrapBintools` is designed for wrapping a standalone
      # bintools derivation. We hereby copy minimal of their implementation.
      # The `wrap()` is from:
      # https://github.com/NixOS/nixpkgs/blob/bfb7a882678e518398ce9a31a881538679f6f092/pkgs/build-support/bintools-wrapper/default.nix#L178
      + optionalString (pname == "rustc") ''
        wrap() {
          local dst="$1"
          local wrapper="$2"
          export prog="$3"
          export use_response_file_by_default=0
          substituteAll "$wrapper" "$dst"
          chmod +x "$dst"
        }

        dsts=( "$out"/lib/rustlib/*/bin/gcc-ld/ld.lld )
        if [[ ''${#dsts} -ne 0 ]]; then
          mkdir -p $out/nix-support
          substituteAll ${path + "/pkgs/build-support/wrapper-common/utils.bash"} $out/nix-support/utils.bash
          substituteAll ${path + "/pkgs/build-support/bintools-wrapper/add-flags.sh"} $out/nix-support/add-flags.sh
          substituteAll ${path + "/pkgs/build-support/bintools-wrapper/add-hardening.sh"} $out/nix-support/add-hardening.sh
          ${
            let
              # This script exists on all platforms, but only in recent nixpkgs.
              p = path + "/pkgs/build-support/wrapper-common/darwin-sdk-setup.bash";
            in optionalString (builtins.pathExists p) ''
              substituteAll ${p} $out/nix-support/darwin-sdk-setup.bash
            '' + optionalString targetPlatform.isDarwin ''
              substituteAll \
                ${path + "/pkgs/build-support/bintools-wrapper/add-darwin-ldflags-before.sh"} \
                $out/nix-support/add-local-ldflags-before.sh
            ''
          }

          for dst in "''${dsts[@]}"; do
            # The ld.lld is path/name sensitive because itself is a wrapper. Keep its original name.
            unwrapped="$(dirname "$dst")-unwrapped/ld.lld"
            mkdir -p "$(dirname "$unwrapped")"
            mv "$dst" "$unwrapped"
            wrap "$dst" ${path + "/pkgs/build-support/bintools-wrapper/ld-wrapper.sh"} "$unwrapped"
          done
        fi
      ''
      + optionalString (stdenv.isLinux && pname == "cargo") ''
        patchelf --add-needed ${pkgsHostHost.libsecret}/lib/libsecret-1.so.0 $out/bin/cargo
      '';

      env = lib.optionalAttrs (pname == "rustc") ({
        inherit (stdenv.cc.bintools) expandResponseParams shell suffixSalt wrapperName coreutils_bin;
        hardening_unsupported_flags = "";

        # These envvars are used by darwin specific scripts.
        # See: https://github.com/NixOS/nixpkgs/blob/0a14706530dcb90acecb81ce0da219d88baaae75/pkgs/build-support/bintools-wrapper/default.nix
        fallback_sdk = optionalString (apple-sdk != null && targetPlatform.isDarwin)
          (apple-sdk.__spliced.buildTarget or apple-sdk);
      } // lib.mapAttrs (_: lib.optionalString targetPlatform.isDarwin) {
        inherit (targetPlatform)
          darwinPlatform darwinSdkVersion
          darwinMinVersion darwinMinVersionVariable;
      });

      dontStrip = true;

      meta = lib.optionalAttrs (elem pname [ "rustc" "rustfmt-preview" "rust-analyzer-preview" "cargo" ] ) ({
        mainProgram = lib.removeSuffix "-preview" pname;
      });
    };

  self = mapAttrs mkComponent srcs;

in
  removeNulls (
    self //
    mapAttrs (alias: { to }: self.${to} or null) renames)
