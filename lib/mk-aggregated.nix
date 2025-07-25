{
  lib,
  stdenv,
  symlinkJoin,
  pkgsTargetTarget,
  bash,
  curl,
  rustc,
}:
{
  pname,
  version,
  date,
  selectedComponents,
  availableComponents ? selectedComponents,
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

  # CC for build script linking.
  # Workaround: should be `pkgsHostHost.cc` but `stdenv`'s cc itself have -1 offset.
  depsHostHostPropagated = [ stdenv.cc ];

  # CC for crate linking.
  # Workaround: should be `pkgsHostTarget.cc` but `stdenv`'s cc itself have -1 offset.
  # N.B. WASM targets don't need our CC.
  propagatedBuildInputs = optional (!targetPlatform.isWasm) pkgsTargetTarget.stdenv.cc;

  # Link dependency for target, required by darwin std.
  depsTargetTargetPropagated = optional (targetPlatform.isDarwin) pkgsTargetTarget.libiconv;

  # If rustc or rustdoc is in the derivation, we need to copy their
  # executable into the final derivation. This is required
  # for making them find the correct SYSROOT.
  postBuild = ''
    for file in $out/bin/{rustc,rustdoc,miri,cargo-miri}; do
      if [ -e $file ]; then
        cp --remove-destination "$(realpath -e $file)" $file
      fi
    done
  ''
  # Workaround: https://github.com/rust-lang/rust/pull/103660
  # FIXME: This duplicates the space usage since `librustc_driver` is huge.
  + lib.optionalString (date == null || date >= "2022-11-01") ''
    for file in $out/bin/{rustc,rustdoc,miri,cargo-miri,cargo-clippy,clippy-driver}; do
      if [ -e $file ]; then
        [[ $file != */*clippy* ]] || cp --remove-destination "$(realpath -e $file)" $file
        chmod +w $file
        ${lib.optionalString stdenv.isLinux ''
          if prev_rpath="$(patchelf --print-rpath "$file")"; then
            patchelf --set-rpath "$out/lib''${prev_rpath:+:}$prev_rpath" "$file"
          fi
        ''}
        ${lib.optionalString stdenv.isDarwin ''
          install_name_tool -add_rpath $out/lib "$file" || true
        ''}
      fi
    done
    ${lib.optionalString stdenv.isDarwin ''
      cargo="$out/bin/cargo"
      if [ -e "$cargo" ]; then
        cp --remove-destination "$(realpath -e $cargo)" "$cargo"
        chmod +w "$cargo"
        install_name_tool -change "/usr/lib/libcurl.4.dylib" "${curl.out}/lib/libcurl.4.dylib" "$cargo"
      fi
    ''}
    shopt nullglob
    for file in $out/lib/librustc_driver*; do
      cp --remove-destination "$(realpath -e $file)" $file
    done

    # installed with rustc-dev
    for file in $out/lib/rustlib/*/lib/librustc_driver*; do
      cp --remove-destination "$(realpath -e $file)" $file
    done
  ''
  + ''
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
