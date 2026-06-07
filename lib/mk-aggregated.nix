{
  lib,
  stdenv,
  symlinkJoin,
  pkgsTargetTarget,
  pkgsHostHost,
  bash,
  curl,
  rustc,
  makeWrapper,
}:
{
  pname,
  version,
  date,
  selectedComponents,
  availableComponents ? selectedComponents,
  enableLibsecret ? false,
}:
let
  inherit (lib) optional;
  inherit (stdenv) targetPlatform;
in
symlinkJoin {
  name = pname + "-" + version;
  inherit pname version;

  paths = selectedComponents;

  passthru = {
    inherit availableComponents;

    # These are used by `buildRustPackage` for default `meta`. We forward
    # them to nixpkgs' rustc, or fallback to sane defaults. False-positive
    # is better than false-negative which causes eval failures.
    # See:
    # - https://github.com/oxalica/rust-overlay/issues/191
    # - https://github.com/NixOS/nixpkgs/pull/338999
    targetPlatforms = rustc.targetPlatforms or lib.platforms.all;
    tier1TargetPlatforms = rustc.tier1TargetPlatforms or lib.platforms.all;
    badTargetPlatforms = rustc.badTargetPlatforms or [ ];
  };

  # Ourselves have offset -1. In order to make these offset -1 dependencies of downstream derivation,
  # they are offset 0 propagated.

  nativeBuildInputs = [
    makeWrapper
  ];

  # CC for build script linking.
  # Workaround: should be `pkgsHostHost.cc` but `stdenv`'s cc itself have -1 offset.
  depsHostHostPropagated = [ stdenv.cc ];

  # CC for crate linking.
  # Workaround: should be `pkgsHostTarget.cc` but `stdenv`'s cc itself have -1 offset.
  # N.B. WASM targets don't need our CC.
  propagatedBuildInputs = optional (!targetPlatform.isWasm) pkgsTargetTarget.stdenv.cc;

  # Link dependency for target, required by darwin std.
  depsTargetTargetPropagated = optional (targetPlatform.isDarwin) pkgsTargetTarget.libiconv;

  # We want to set the default sysroot to the aggregated directory, but
  # librustc_driver (and all binaries linking to it) will infer the default
  # sysroot relative to librustc_driver. So we need to copy these binaries
  # instead of symlink them.
  # FIXME: This duplicates the space usage. `librustc_driver` is huge (150MiB).
  postBuild = ''
    shopt nullglob
    for file in \
      $out/bin/{rustc,rustdoc,miri,cargo-miri,cargo-clippy,clippy-driver} \
      $out/lib/{librustc_driver*,rustlib/*/lib/librustc_driver*}
    do
      if [ -e $file ]; then
        cp --remove-destination "$(realpath -e $file)" $file
        ${lib.optionalString stdenv.isLinux ''
          chmod +w "$file"
          if prev_rpath="$(patchelf --print-rpath "$file")"; then
            patchelf --set-rpath "$out/lib''${prev_rpath:+:}$prev_rpath" "$file"
          fi
        ''}
      fi
    done

    ${lib.optionalString (stdenv.isDarwin || enableLibsecret) ''
      cargo="$out/bin/cargo"
      if [ -e "$cargo" ]; then
        cargoOriginal="$(readlink "$cargo")"
        rm "$cargo"
        makeWrapper "$cargoOriginal" "$cargo" \
          ${
            # It seems `LD_LIBRARY_PATH` does not work on Darwin, although the documentation says it should.
            # Maybe it is because RPATH takes precedence over LD_LIBRARY_PATH but not over DYLD_LIBRARY_PATH.
            # Note that the upstream cargo has RPATH to a system curl which reads out-of-sandbox paths.
            # See: <https://github.com/oxalica/rust-overlay/pull/251#discussion_r2904701116>
            # Docs: <https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/DynamicLibraries/100-Articles/UsingDynamicLibraries.html>
            lib.optionalString stdenv.isDarwin ''--prefix DYLD_LIBRARY_PATH : "${curl.out}/lib"''
          } \
          ${lib.optionalString enableLibsecret ''--prefix LD_LIBRARY_PATH : "${pkgsHostHost.libsecret}/lib"''} \

      fi
    ''}

    if [ -e $out/bin/cargo-miri ]; then
      mv $out/bin/{cargo-miri,.cargo-miri-wrapped}
      cp -f ${./cargo-miri-wrapper.sh} $out/bin/cargo-miri
      chmod +w $out/bin/cargo-miri
      substituteInPlace $out/bin/cargo-miri \
        --replace "@bash@" "${bash}/bin/bash" \
        --replace "@cargo_miri@" "$out/bin/.cargo-miri-wrapped" \
        --replace "@out@" "$out"
    fi

    # symlinkJoin doesn't automatically handle it. Thus do it manually.
    mkdir -p $out/nix-support
    echo "$depsHostHostPropagated " >$out/nix-support/propagated-host-host-deps
    [[ -z "$propagatedBuildInputs" ]] || echo "$propagatedBuildInputs " >$out/nix-support/propagated-build-inputs
    [[ -z "$depsTargetTargetPropagated" ]] || echo "$depsTargetTargetPropagated " >$out/nix-support/propagated-target-target-deps
  '';

  meta.platforms = lib.platforms.all;
}
