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
      "aarch64-darwin"
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

    packages = let
      inherit (builtins) tryEval;

      defaultPkg = comps:
        if comps ? default then
          if (tryEval comps.default.drvPath).success then
            comps.default
          else if (tryEval comps.minimal.drvPath).success then
            comps.minimal
          else
            null
        else if (tryEval comps.rust.drvPath).success then
          comps.rust
        else
          null;

      result =
        lib.mapAttrs' (version: comps: {
          name = "rust-${lib.replaceStrings ["."] ["-"] version}";
          value = defaultPkg comps;
        }) pkgs.rust-bin.stable //
        lib.mapAttrs' (version: comps: {
          name = "rust-nightly-${version}";
          value = defaultPkg comps;
        }) pkgs.rust-bin.nightly //
        lib.mapAttrs' (version: comps: {
          name = "rust-beta-${version}";
          value = defaultPkg comps;
        }) pkgs.rust-bin.beta //
        {
          rust = result.rust-latest;
          rust-nightly = result.rust-nightly-latest;
          rust-beta = result.rust-beta-latest;
        };
    in lib.filterAttrs (name: drv: drv != null) result;

    checks = let
      inherit (pkgs) rust-bin rustChannelOf;
      inherit (pkgs.rust-bin) fromRustupToolchain fromRustupToolchainFile stable beta nightly;

      rustTarget = pkgs.rust.toRustTarget pkgs.hostPlatform;

      assertEq = lhs: rhs: {
        assertion = lhs == rhs;
        message = "`${lhs}` != `${rhs}`";
      };
      assertUrl = drv: url: let
        srcUrl = lib.head drv.src.urls;
      in assertEq srcUrl url;

      assertions = {
        url-no-arch = assertUrl stable."1.48.0".rust-src "https://static.rust-lang.org/dist/2020-11-19/rust-src-1.48.0.tar.xz";
        url-kind-nightly = assertUrl nightly."2021-01-01".rustc "https://static.rust-lang.org/dist/2021-01-01/rustc-nightly-${rustTarget}.tar.xz";
        url-kind-beta = assertUrl beta."2021-01-01".rustc "https://static.rust-lang.org/dist/2021-01-01/rustc-beta-${rustTarget}.tar.xz";

      # Check only tier 1 targets.
      } // lib.optionalAttrs (lib.elem system [ "aarch64-linux" "x86_64-linux" ]) {

        name-stable = assertEq stable."1.48.0".rustc.name "rustc-1.48.0";
        name-beta = assertEq beta."2021-01-01".rustc.name "rustc-1.50.0-beta.2-2021-01-01";
        name-nightly = assertEq nightly."2021-01-01".rustc.name "rustc-1.51.0-nightly-2021-01-01";
        name-stable-profile-default = assertEq stable."1.51.0".default.name "rust-default-1.51.0";
        name-stable-profile-minimal = assertEq stable."1.51.0".minimal.name "rust-minimal-1.51.0";

        url-kind-2 = assertUrl stable."1.48.0".cargo "https://static.rust-lang.org/dist/2020-11-19/cargo-1.48.0-${rustTarget}.tar.xz";
        url-kind-0 = assertUrl stable."1.47.0".cargo "https://static.rust-lang.org/dist/2020-10-08/cargo-0.48.0-${rustTarget}.tar.xz";
        url-kind-1 = assertUrl stable."1.34.2".llvm-tools-preview "https://static.rust-lang.org/dist/2019-05-14/llvm-tools-1.34.2%20(6c2484dc3%202019-05-13)-${rustTarget}.tar.xz";
        url-fix = assertUrl nightly."2019-01-10".rustc "https://static.rust-lang.org/dist/2019-01-10/rustc-nightly-${rustTarget}.tar.xz";

        rename-available = assertEq stable."1.48.0".rustfmt stable."1.48.0".rustfmt-preview;
        rename-unavailable = {
          assertion = !(stable."1.30.0" ? rustfmt);
          message = "1.30.0 has rustfmt still in preview state";
        };

        latest-stable-legacy = assertEq pkgs.latest.rustChannels.stable.rustc stable.latest.rustc;
        latest-beta-legacy = assertEq pkgs.latest.rustChannels.beta.rustc beta.latest.rustc;
        latest-nightly-legacy = assertEq pkgs.latest.rustChannels.nightly.rustc nightly.latest.rustc;

        rust-channel-of-stable = assertEq (rustChannelOf { channel = "stable"; }).rustc stable.latest.rustc;
        rust-channel-of-beta = assertEq (rustChannelOf { channel = "beta"; }).rustc beta.latest.rustc;
        rust-channel-of-nightly = assertEq (rustChannelOf { channel = "nightly"; }).rustc nightly.latest.rustc;
        rust-channel-of-version = assertEq (rustChannelOf { channel = "1.48.0"; }).rustc stable."1.48.0".rustc;
        rust-channel-of-nightly-date = assertEq (rustChannelOf { channel = "nightly"; date = "2021-01-01"; }).rustc nightly."2021-01-01".rustc;
        rust-channel-of-beta-date = assertEq (rustChannelOf { channel = "beta"; date = "2021-01-01"; }).rustc beta."2021-01-01".rustc;

        rustup-toolchain-stable = assertEq (fromRustupToolchain { channel = "stable"; }) stable.latest.default;
        rustup-toolchain-beta = assertEq (fromRustupToolchain { channel = "beta"; }) beta.latest.default;
        # rustup-toolchain-nightly = assertEq (fromRustupToolchain { channel = "nightly"; }) nightly.latest.default; # Not always available
        rustup-toolchain-version = assertEq (fromRustupToolchain { channel = "1.51.0"; }) stable."1.51.0".default;
        rustup-toolchain-nightly-date = assertEq (fromRustupToolchain { channel = "nightly-2021-01-01"; }) nightly."2021-01-01".default;
        rustup-toolchain-beta-date = assertEq (fromRustupToolchain { channel = "beta-2021-01-01"; }) beta."2021-01-01".default;
        rustup-toolchain-customization = assertEq
          (fromRustupToolchain {
            channel = "1.51.0";
            components = [ "rustfmt" "rustc-dev" ];
            targets = [ "wasm32-unknown-unknown" "aarch64-unknown-linux-gnu" ];
          })
          (stable."1.51.0".default.override {
            extensions = [ "rustfmt" "rustc-dev" ];
            targets = [ "wasm32-unknown-unknown" "aarch64-unknown-linux-gnu" ];
          });

        rustup-toolchain-profile-missing = assertEq (builtins.tryEval (fromRustupToolchain { channel = "1.51.0"; profile = "non_existent"; })).success false;
        rustup-toolchain-profile-too-early = assertEq (builtins.tryEval (fromRustupToolchain { channel = "1.29.0"; profile = "minimal"; })).success false;
        rustup-toolchain-profile-fallback = assertEq (fromRustupToolchain { channel = "1.29.0"; }) stable."1.29.0".rust;

        rustup-toolchain-file-toml = assertEq
          (fromRustupToolchainFile ./tests/rust-toolchain-toml)
          (nightly."2021-03-25".default.override {
            extensions = [ "rustfmt" "rustc-dev" ];
            targets = [ "wasm32-unknown-unknown" "aarch64-unknown-linux-gnu" ];
          });
        rustup-toolchain-file-legacy = assertEq
          (fromRustupToolchainFile ./tests/rust-toolchain-legacy)
          nightly."2021-03-25".default;
        rustup-toolchain-file-minimal = assertEq
          (fromRustupToolchainFile ./tests/rust-toolchain-minimal)
          (nightly."2021-03-25".minimal.override {
            extensions = [ "rustfmt" "rustc-dev" ];
            targets = [ "aarch64-unknown-linux-gnu" ];
          });
      };

      checkDrvs = lib.optionalAttrs (lib.elem system [ "aarch64-linux" "x86_64-linux" ]) {
        latest-nightly-default = rust-bin.selectLatestNightlyWith (toolchain: toolchain.default);
      };

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
