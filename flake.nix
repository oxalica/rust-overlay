{
  description = ''
    Pure and reproducible overlay for binary distributed rust toolchains.
    A compatible but better replacement for rust overlay of github:mozilla/nixpkgs-mozilla.
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }: let
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
      }) pkgs.rust-bin.stable //
      lib.mapAttrs' (version: comps: {
        name = "rust-nightly-${version}";
        value = comps.rust;
      }) (removeAttrs pkgs.rust-bin.nightly [ "2018-11-01" "2020-09-12" ]) // # FIXME: `rust` is not available.
      lib.mapAttrs' (version: comps: {
        name = "rust-beta-${version}";
        value = comps.rust;
      }) (removeAttrs pkgs.rust-bin.beta [ "2018-11-09" ]) // # FIXME: `rust` is not available.
      {
        rust = packages.rust-latest;
        rust-nightly = packages.rust-nightly-latest;
        rust-beta = packages.rust-beta-latest;
      };

    checks = let
      inherit (pkgs) rust-bin rustChannelOf;
      inherit (pkgs.rust-bin) fromRustupToolchain fromRustupToolchainFile stable beta nightly;

      rustTarget = pkgs.rust.toRustTarget pkgs.hostPlatform;

      assertEq = lhs: rhs: {
        assertion = lhs == rhs;
        message = "`${lhs}` != `${rhs}`";
      };
      assertUrl = drv: url: let
        srcUrl = lib.head (lib.head drv.paths).src.urls;
      in assertEq srcUrl url;

      assertions = {
        url-no-arch = assertUrl stable."1.48.0".rust-src "https://static.rust-lang.org/dist/2020-11-19/rust-src-1.48.0.tar.xz";
        url-kind-2 = assertUrl stable."1.48.0".cargo "https://static.rust-lang.org/dist/2020-11-19/cargo-1.48.0-${rustTarget}.tar.xz";
        url-kind-0 = assertUrl stable."1.47.0".cargo "https://static.rust-lang.org/dist/2020-10-08/cargo-0.48.0-${rustTarget}.tar.xz";
        url-kind-1 = assertUrl stable."1.34.2".llvm-tools-preview "https://static.rust-lang.org/dist/2019-05-14/llvm-tools-1.34.2%20(6c2484dc3%202019-05-13)-${rustTarget}.tar.xz";
        url-kind-nightly = assertUrl nightly."2021-01-01".rustc "https://static.rust-lang.org/dist/2021-01-01/rustc-nightly-${rustTarget}.tar.xz";
        url-kind-beta = assertUrl beta."2021-01-01".rustc "https://static.rust-lang.org/dist/2021-01-01/rustc-beta-${rustTarget}.tar.xz";
        url-fix = assertUrl nightly."2019-01-10".rustc "https://static.rust-lang.org/dist/2019-01-10/rustc-nightly-${rustTarget}.tar.xz";

        rename-available = assertEq stable."1.48.0".rustfmt stable."1.48.0".rustfmt-preview;
        rename-unavailable = {
          assertion = !(stable."1.30.0" ? rustfmt);
          message = "1.30.0 has rustfmt still in preview state";
        };

        latest-stable = assertEq pkgs.latest.rustChannels.stable.rust stable.latest.rust;
        latest-beta = assertEq pkgs.latest.rustChannels.beta.rust beta.latest.rust;
        latest-nightly = assertEq pkgs.latest.rustChannels.nightly.rust nightly.latest.rust;

        rust-channel-of-stable = assertEq (rustChannelOf { channel = "stable"; }).rust stable.latest.rust;
        rust-channel-of-beta = assertEq (rustChannelOf { channel = "beta"; }).rust beta.latest.rust;
        rust-channel-of-nightly = assertEq (rustChannelOf { channel = "nightly"; }).rust nightly.latest.rust;
        rust-channel-of-version = assertEq (rustChannelOf { channel = "1.48.0"; }).rust stable."1.48.0".rust;
        rust-channel-of-nightly-date = assertEq (rustChannelOf { channel = "nightly"; date = "2021-01-01"; }).rust nightly."2021-01-01".rust;
        rust-channel-of-beta-date = assertEq (rustChannelOf { channel = "beta"; date = "2021-01-01"; }).rust beta."2021-01-01".rust;

        rustup-toolchain-stable = assertEq (fromRustupToolchain { channel = "stable"; }) stable.latest.rust;
        rustup-toolchain-beta = assertEq (fromRustupToolchain { channel = "beta"; }) beta.latest.rust;
        rustup-toolchain-nightly = assertEq (fromRustupToolchain { channel = "nightly"; }) nightly.latest.rust;
        rustup-toolchain-version = assertEq (fromRustupToolchain { channel = "1.48.0"; }) stable."1.48.0".rust;
        rustup-toolchain-nightly-date = assertEq (fromRustupToolchain { channel = "nightly-2021-01-01"; }) nightly."2021-01-01".rust;
        rustup-toolchain-beta-date = assertEq (fromRustupToolchain { channel = "beta-2021-01-01"; }) beta."2021-01-01".rust;
        rustup-toolchain-customization = assertEq
          (fromRustupToolchain {
            channel = "1.48.0";
            components = [ "rustfmt" "rustc-dev" ];
            targets = [ "wasm32-unknown-unknown" "aarch64-unknown-linux-gnu" ];
          })
          (stable."1.48.0".rust.override {
            extensions = [ "rustfmt" "rustc-dev" ];
            targets = [ "wasm32-unknown-unknown" "aarch64-unknown-linux-gnu" ];
          });

        rustup-toolchain-file-toml = assertEq
          (fromRustupToolchainFile ./tests/rust-toolchain-toml)
          (nightly."2020-07-10".rust.override {
            extensions = [ "rustfmt" "rustc-dev" ];
            targets = [ "wasm32-unknown-unknown" "aarch64-unknown-linux-gnu" ];
          });
        rustup-toolchain-file-legacy = assertEq
          (fromRustupToolchainFile ./tests/rust-toolchain-legacy)
          nightly."2020-07-10".rust;
      };

      checkDrvs = {};

      failedAssertions =
        lib.filter (msg: msg != null) (
          lib.mapAttrsToList
          (name: { assertion, message }: if assertion
            then null
            else "Assertion `${name}` failed: ${message}\n")
          assertions);

    in if failedAssertions == []
      then checkDrvs
      else throw (builtins.toString failedAssertions);

  });
}
