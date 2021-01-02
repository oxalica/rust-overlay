{
  description = ''
    Pure and reproducible overlay for binary distributed rust toolchains.
    A compatible but better replacement for rust overlay of github:mozilla/nixpkgs-mozilla.
  '';

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }@inputs: let
    inherit (nixpkgs) lib;

    overlay = import ./.;

    allSystems = [
      "aarch64-linux"
      "armv6l-linux"
      "armv7a-linux"
      "armv7l-linux"
      "x86_64-linux"
      "x86_64-darwin"
      # "aarch64-darwin"
    ];

  in {

    overlay = final: prev: overlay final prev;

  } // flake-utils.lib.eachSystem allSystems (system: let
    pkgs = import nixpkgs { inherit system; overlays = [ overlay ]; };
  in rec {
    # `defaultApp`, `defaultPackage` and `packages` are for human only.
    # They are subject to change and **DO NOT** depend on them in your flake.
    # Please use `overlay` instead.

    defaultApp = {
      type = "app";
      program = "${defaultPackage}/bin/rustc";
    };
    defaultPackage = packages.rust;

    # FIXME: We can only directly provide derivations here without nested set.
    # Currently we only provide stable releases. Some nightly versions have components missing
    # on some platforms, which makes `nix flake check` to be failed.
    packages =
      lib.mapAttrs' (version: comps: {
        name = "rust-${lib.replaceStrings ["."] ["-"] version}";
        value = comps.rust;
      }) pkgs.rust-bin.stable // {
        rust = packages.rust-latest;
      };

    checks = {
      kind2 = (pkgs.rustChannelOf { channel = "1.48.0"; }).rust;
      kind0 = (pkgs.rustChannelOf { channel = "1.47.0"; }).rust;
      kind1 = (pkgs.rustChannelOf { channel = "1.34.2"; }).llvm-tools-preview;
      kind-nightly = (pkgs.rustChannelOf { channel = "nightly"; date = "2021-01-01"; }).rust;
      url-fix = (pkgs.rustChannelOf { channel = "nightly"; date = "2019-01-10"; }).rust;
    };
  });
}
