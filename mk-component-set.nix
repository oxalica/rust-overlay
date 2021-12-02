# Define component derivations and special treatments.
{ lib, stdenv, buildPackages, gnutar, gcc, zlib, libiconv
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
    stdenv.mkDerivation {
      inherit pname version src;

      passthru.platform = platform;

      # No point copying src to a build server, then copying back the
      # entire unpacked contents after just a little twiddling.
      preferLocalBuild = true;

      nativeBuildInputs = [ gnutar ];

      # Ourselves have offset -1. In order to make these offset -1 dependencies of downstream derivation,
      # they are offset 0 propagated.
      propagatedBuildInputs =
        optional (pname == "rustc") [ stdenv.cc buildPackages.stdenv.cc ];
      # This goes downstream packages' buildInputs.
      depsTargetTargetPropagated =
        optional (pname == "rustc" && targetPlatform.isDarwin) libiconv;

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

      # This code is inspired by patchelf/setup-hook.sh to iterate over all binaries.
      preFixup =
        optionalString hostPlatform.isLinux ''
          setInterpreter() {
            local dir="$1"
            [ -e "$dir" ] || return 0
            header "Patching interpreter of ELF executables and libraries in $dir"
            local i
            while IFS= read -r -d ''$'\0' i; do
              if [[ "$i" =~ .build-id ]]; then continue; fi
              if ! isELF "$i"; then continue; fi
              echo "setting interpreter of $i"

              if [[ -x "$i" ]]; then
                # Handle executables
                patchelf \
                  --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
                  --set-rpath "${makeLibraryPath [ zlib ]}:$out/lib" \
                  "$i" || true
              else
                # Handle libraries
                patchelf \
                  --set-rpath "${makeLibraryPath [ zlib ]}:$out/lib" \
                  "$i" || true
              fi
            done < <(find "$dir" -type f -print0)
          }
          setInterpreter $out
        '' + optionalString (elem pname ["clippy-preview" "rls-preview" "miri-preview"]) ''
          for f in $out/bin/*; do
            ${optionalString hostPlatform.isLinux ''
              patchelf \
                --set-rpath "${self.rustc}/lib:${makeLibraryPath [ zlib ]}:$out/lib" \
                "$f" || true
            ''}
            ${optionalString hostPlatform.isDarwin ''
              install_name_tool \
                -add_rpath "${self.rustc}/lib" \
                "$f" || true
            ''}
          done
        '' + optionalString (pname == "llvm-tools-preview" && hostPlatform.isLinux) ''
          dir="$out/lib/rustlib/${toRustTarget hostPlatform}"
          for f in "$dir"/bin/*; do
            patchelf --set-rpath "$dir/lib" "$f" || true
          done
        '';

      # rust-docs only contains tons of html files.
      dontFixup = pname == "rust-docs";

      postFixup = ''
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

      dontStrip = true;
    };

  self = mapAttrs mkComponent srcs;

in
  removeNulls (
    self //
    mapAttrs (alias: { to }: self.${to} or null) renames)
