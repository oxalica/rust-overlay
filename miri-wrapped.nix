{ lib, pkgs, stdenv, makeRustPlatform, fetchFromGitHub, runCommand, writeShellScriptBin
, toRustTarget, rustc, cargo, rust-std, rust-src, miri-preview
}:
let
  rustc' = writeShellScriptBin "rustc"  ''
    if [[ " --sysroot " == " $* " ]]; then
      exec ${rustc}/bin/rustc "$@"
    else
      exec ${rustc}/bin/rustc --sysroot ${rust-std} "$@"
    fi
  '';

  rustPlatform = makeRustPlatform {
    inherit cargo;
    rustc = rustc';
    # Follow nixpkgs' rustc to make `makeRustPlatform` happy.
    # rustc = rustc // { meta.platforms = pkgs.rustc.meta.platforms; };
  };

  rustHostPlatform = toRustTarget stdenv.hostPlatform;
  rustHostPlatform' = lib.replaceStrings ["-"] ["_"] (lib.toUpper rustHostPlatform);

  xargo = rustPlatform.buildRustPackage rec {
    pname = "xargo";
    version = "0.3.26";

    src = fetchFromGitHub {
      owner = "japaric";
      repo = "xargo";
      rev = "v${version}";
      hash = "sha256-MPopR58EIPiLg79wxf3nDy6SitdsmuUCjOLut8+fFJ4=";
    };

    cargoHash = "sha256-LmOu7Ni6TkACHy/ZG8ASG/P2UWEs3Qljz4RGSW1i3zk=";

    dontCargoCheck = true;

    meta.license = with lib.licenses; [ mit asl20 ];
    meta.platforms = pkgs.rustc.meta.platforms;
  };

  miri-sysroot = runCommand "miri-sysroot" {
    nativeBuildInputs = [ rustc' cargo xargo miri-preview pkgs.breakpointHook ];
    # RUSTFLAGS = [ "--sysroot" rust-std ];
    XARGO_RUST_SRC = "${rust-src}/lib/rustlib/src/rust/library";
  } ''
    mkdir -p home
    export HOME="$(pwd)/home"
    cargo miri setup

    sysroot="$(cargo miri setup --print-sysroot)"
    cp -rT "$sysroot" "$out"
  '';

  miri-wrapped = runCommand "miri-wrapped" {
    inherit (miri-preview) version meta;
  } ''
    mkdir -p $out/bin
    ln -s ${miri-preview}/share $out/share
    for file in miri cargo-miri; do
      makeWrapper ${miri-preview}/bin/$file $out/bin/$file \
        --set-default MIRI_SYSROOT ${miri-sysroot}
    done
  '';

in
  miri-wrapped
