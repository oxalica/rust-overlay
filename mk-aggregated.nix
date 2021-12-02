{ lib, stdenv, symlinkJoin, pkgsTargetTarget, bash, gcc }:
{ pname, version, components }:
let
  inherit (lib) optional optionalString;
in
symlinkJoin {
  name = pname + "-" + version;
  inherit pname version;

  paths = components;

  # Ourselves have offset -1. In order to make these offset -1 dependencies of downstream derivation,
  # they are offset 0 propagated.

  # CC for build script linking.
  # Workaround: should be `pkgsHostHost.cc` but `stdenv`'s cc itself have -1 offset.
  depsHostHostPropagated = [ stdenv.cc ];
  # CC for crate linking.
  # Workaround: should be `pkgsHostTarget.cc` but `stdenv`'s cc itself have -1 offset.
  propagatedBuildInputs = [ pkgsTargetTarget.stdenv.cc ];

  # Link dependency for target, required by darwin std.
  depsTargetTargetPropagated =
    optional (stdenv.targetPlatform.isDarwin) [ pkgsTargetTarget.libiconv ];

  postBuild = ''
    # If rustc or rustdoc is in the derivation, we need to copy their
    # executable into the final derivation. This is required
    # for making them find the correct SYSROOT.
    for target in $out/bin/{rustc,rustdoc,miri,cargo-miri}; do
      if [ -e $target ]; then
        cp --remove-destination "$(realpath -e $target)" $target
      fi
    done

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
    mkdir $out/nix-support
    echo "$depsHostHostPropagated " >$out/nix-support/propagated-host-host-deps
    echo "$propagatedBuildInputs " >$out/nix-support/propagated-build-inputs
  '' + optionalString (stdenv.targetPlatform.isDarwin) ''
    echo "$depsTargetTargetPropagated " >$out/nix-support/propagated-target-target-deps
  '';

  meta.platforms = lib.platforms.all;
}
