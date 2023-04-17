{
  description = ''
    Pure and reproducible overlay for binary distributed rust toolchains.
    A compatible but better replacement for rust overlay of github:mozilla/nixpkgs-mozilla.
  '';

  inputs = {
    # See: https://github.com/nix-systems/nix-systems
    systems.url = "path:./systems.nix";
    systems.flake = false;
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, systems, nixpkgs }: let
    inherit (nixpkgs.lib)
      elem filterAttrs head mapAttrs mapAttrs' optionalAttrs replaceStrings warnIf;

    inherit (builtins)
      nixVersion compareVersions;

    overlay = import ./.;

    eachSystem = nixpkgs.lib.genAttrs (import systems);

    overlayOutputFor = system:
      # Prefer to reuse may-be-evaluated flake output.
      if nixpkgs ? legacyPackages.${system} then
        let
          super = nixpkgs.legacyPackages.${system};
          final = super // overlay final super;
        in
          final
      # Otherwise, fallback to import.
      else
        import nixpkgs { inherit system; overlays = [ overlay ]; };

  in {
    overlays = {
      default = overlay;
      rust-overlay = overlay;
    };

    # Compatible fields.
    # Put them outside `eachSystem` to suppress duplicated warnings.
    overlay =
      warnIf (compareVersions nixVersion "2.7" >= 0)
        "rust-overlay's flake output `overlay` is deprecated in favor of `overlays.default` for Nix >= 2.7"
        overlay;
    defaultPackage =
      warnIf (compareVersions nixVersion "2.7" >= 0)
        "rust-overlay's flake output `defaultPackage.<system>` is deprecated in favor of `packages.<system>.default` for Nix >= 2.7"
        (mapAttrs (_: pkgs: pkgs.default) self.packages);

    # TODO: Flake outputs other than `overlay[s]` are not stabilized yet.

    packages = let
      select = version: comps: if version == "latest" then null else comps.default or null;
      resultOf = rust-bin:
        mapAttrs' (version: comps: {
          name = "rust_${replaceStrings ["."] ["_"] version}";
          value = select version comps;
        }) rust-bin.stable //
        mapAttrs' (version: comps: {
          name = "rust-nightly_${version}";
          value = select version comps;
        }) rust-bin.nightly //
        mapAttrs' (version: comps: {
          name = "rust-beta_${version}";
          value = select version comps;
        }) rust-bin.beta //
        rec {
          rust = rust-bin.stable.latest.default;
          rust-beta = rust-bin.beta.latest.default;
          rust-nightly = rust-bin.nightly.latest.default;
          default = rust;
        };
    in
      eachSystem (system:
        filterAttrs (name: drv: drv != null)
          (resultOf ((overlayOutputFor system).rust-bin)));

    checks = eachSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      inherit (overlayOutputFor system) rust-bin rustChannelOf latest;
      inherit (rust-bin) fromRustupToolchain fromRustupToolchainFile stable beta nightly;

      rustHostPlatform = pkgs.rust.toRustTarget pkgs.hostPlatform;

      assertEq = lhs: rhs: assert lhs == rhs; pkgs.runCommandNoCCLocal "OK" { } ">$out";
      assertUrl = drv: url: assertEq (head drv.src.urls) url;
    in
      # Check only tier 1 targets.
      optionalAttrs (elem system [ "aarch64-linux" "x86_64-linux" ]) {
        url-no-arch = assertUrl stable."1.48.0".rust-src "https://static.rust-lang.org/dist/2020-11-19/rust-src-1.48.0.tar.xz";
        url-kind-nightly = assertUrl nightly."2021-01-01".rustc "https://static.rust-lang.org/dist/2021-01-01/rustc-nightly-${rustHostPlatform}.tar.xz";
        url-kind-beta = assertUrl beta."2021-01-01".rustc "https://static.rust-lang.org/dist/2021-01-01/rustc-beta-${rustHostPlatform}.tar.xz";

        name-stable = assertEq stable."1.48.0".rustc.name "rustc-1.48.0-${rustHostPlatform}";
        name-beta = assertEq beta."2021-01-01".rustc.name "rustc-1.50.0-beta.2-2021-01-01-${rustHostPlatform}";
        name-nightly = assertEq nightly."2021-01-01".rustc.name "rustc-1.51.0-nightly-2021-01-01-${rustHostPlatform}";
        name-stable-profile-default = assertEq stable."1.51.0".default.name "rust-default-1.51.0";
        name-stable-profile-minimal = assertEq stable."1.51.0".minimal.name "rust-minimal-1.51.0";

        url-kind-2 = assertUrl stable."1.48.0".cargo "https://static.rust-lang.org/dist/2020-11-19/cargo-1.48.0-${rustHostPlatform}.tar.xz";
        url-kind-0 = assertUrl stable."1.47.0".cargo "https://static.rust-lang.org/dist/2020-10-08/cargo-0.48.0-${rustHostPlatform}.tar.xz";
        url-kind-1 = assertUrl stable."1.34.2".llvm-tools-preview "https://static.rust-lang.org/dist/2019-05-14/llvm-tools-1.34.2%20(6c2484dc3%202019-05-13)-${rustHostPlatform}.tar.xz";
        url-fix = assertUrl nightly."2019-01-10".rustc "https://static.rust-lang.org/dist/2019-01-10/rustc-nightly-${rustHostPlatform}.tar.xz";

        # 1.30.0 has `rustfmt` still in preview state.
        rename-unavailable = assertEq (stable."1.30.0" ? rustfmt) false;
        rename-available = assertEq stable."1.48.0".rustfmt stable."1.48.0".rustfmt-preview;

        latest-stable-legacy = assertEq latest.rustChannels.stable.rustc stable.latest.rustc;
        latest-beta-legacy = assertEq latest.rustChannels.beta.rustc beta.latest.rustc;
        latest-nightly-legacy = assertEq latest.rustChannels.nightly.rustc nightly.latest.rustc;

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

        latest-nightly-default = rust-bin.selectLatestNightlyWith (toolchain: toolchain.default);

      # Darwin specific tests.
      } // optionalAttrs (system == "aarch64-darwin") {
        url-forward = assertUrl
          nightly."2022-02-02".rust-docs
          "https://static.rust-lang.org/dist/2022-02-02/rust-docs-nightly-x86_64-apple-darwin.tar.xz";
        aarch64-darwin-use-x86-docs = rust-bin.stable."1.51.0".default.override {
          targets = [ "x86_64-apple-darwin" ];
          targetExtensions = [ "rust-docs" ];
        };
      });
  };
}
