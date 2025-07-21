inputs: system:
let
  inherit (inputs.nixpkgs) lib;
  inherit (lib) head optionalAttrs elem;
  inherit (builtins) toJSON toFile tryEval;

  pkgs-compat = import inputs.nixpkgs {
    inherit system;
    overlays = [ inputs.self.overlays.default ];
  };
  inherit (pkgs-compat) latest rustChannelOf;

  pkgs = inputs.nixpkgs.legacyPackages.${system};
  rustHostPlatform = pkgs.hostPlatform.rust.rustcTarget;

  rust-bin = inputs.self.lib.mkRustBin { } pkgs;
  inherit (rust-bin)
    fromRustupToolchain
    fromRustupToolchainFile
    stable
    beta
    nightly
    ;

  assertEq =
    lhs: rhs:
    if lhs == rhs then
      pkgs.emptyFile
    else
      derivation {
        inherit system;
        name = "assert-failure";
        builder = "/bin/sh";
        args = [
          "-c"
          ''echo "LHS: $lhs"; echo "RHS: $rhs"; exit 1''
        ];
        lhs = toJSON lhs;
        rhs = toJSON rhs;
      };
  assertUrl = drv: url: assertEq (head drv.src.urls) url;

  testNightly = {
    date = "2024-08-01";
    version = "1.82.0-nightly-2024-08-01";
  };
  testBeta = {
    date = "2024-07-26";
    version = "1.81.0-beta.2-2024-07-26";
  };

in
# Check only tier 1 targets.
optionalAttrs
  (elem system [
    "aarch64-linux"
    "x86_64-linux"
  ])
  {
    url-no-arch =
      assertUrl stable."1.48.0".rust-src
        "https://static.rust-lang.org/dist/2020-11-19/rust-src-1.48.0.tar.xz";
    url-kind-nightly =
      assertUrl nightly.${testNightly.date}.rustc
        "https://static.rust-lang.org/dist/${testNightly.date}/rustc-nightly-${rustHostPlatform}.tar.xz";
    url-kind-beta =
      assertUrl beta.${testBeta.date}.rustc
        "https://static.rust-lang.org/dist/${testBeta.date}/rustc-beta-${rustHostPlatform}.tar.xz";

    name-stable = assertEq stable."1.48.0".rustc.name "rustc-1.48.0-${rustHostPlatform}";
    name-beta =
      assertEq beta.${testBeta.date}.rustc.name
        "rustc-${testBeta.version}-${rustHostPlatform}";
    name-nightly =
      assertEq nightly.${testNightly.date}.rustc.name
        "rustc-${testNightly.version}-${rustHostPlatform}";
    name-stable-profile-default = assertEq stable."1.51.0".default.name "rust-default-1.51.0";
    name-stable-profile-minimal = assertEq stable."1.51.0".minimal.name "rust-minimal-1.51.0";

    url-kind-2 =
      assertUrl stable."1.48.0".cargo
        "https://static.rust-lang.org/dist/2020-11-19/cargo-1.48.0-${rustHostPlatform}.tar.xz";
    url-kind-0 =
      assertUrl stable."1.47.0".cargo
        "https://static.rust-lang.org/dist/2020-10-08/cargo-0.48.0-${rustHostPlatform}.tar.xz";
    url-kind-1 =
      assertUrl stable."1.34.2".llvm-tools-preview
        "https://static.rust-lang.org/dist/2019-05-14/llvm-tools-1.34.2%20(6c2484dc3%202019-05-13)-${rustHostPlatform}.tar.xz";

    # 1.30.0 has `rustfmt` still in preview state.
    rename-unavailable = assertEq (stable."1.30.0" ? rustfmt) false;
    rename-available = assertEq stable."1.48.0".rustfmt stable."1.48.0".rustfmt-preview;

    latest-stable-legacy = assertEq latest.rustChannels.stable.rustc stable.latest.rustc;
    latest-beta-legacy = assertEq latest.rustChannels.beta.rustc beta.latest.rustc;
    latest-nightly-legacy = assertEq latest.rustChannels.nightly.rustc nightly.latest.rustc;

    rust-channel-of-stable = assertEq (rustChannelOf { channel = "stable"; }).rustc stable.latest.rustc;
    rust-channel-of-beta = assertEq (rustChannelOf { channel = "beta"; }).rustc beta.latest.rustc;
    rust-channel-of-nightly =
      assertEq (rustChannelOf { channel = "nightly"; }).rustc
        nightly.latest.rustc;
    rust-channel-of-version =
      assertEq (rustChannelOf { channel = "1.48.0"; }).rustc
        stable."1.48.0".rustc;
    rust-channel-of-nightly-date =
      assertEq
        (rustChannelOf {
          channel = "nightly";
          date = testNightly.date;
        }).rustc
        nightly.${testNightly.date}.rustc;
    rust-channel-of-beta-date =
      assertEq
        (rustChannelOf {
          channel = "beta";
          date = testBeta.date;
        }).rustc
        beta.${testBeta.date}.rustc;

    rustup-toolchain-stable = assertEq (fromRustupToolchain {
      channel = "stable";
    }) stable.latest.default;
    rustup-toolchain-beta = assertEq (fromRustupToolchain { channel = "beta"; }) beta.latest.default;
    # rustup-toolchain-nightly = assertEq (fromRustupToolchain { channel = "nightly"; }) nightly.latest.default; # Not always available
    rustup-toolchain-version = assertEq (fromRustupToolchain {
      channel = "1.51.0";
    }) stable."1.51.0".default;
    rustup-toolchain-nightly-date = assertEq (fromRustupToolchain {
      channel = "nightly-${testNightly.date}";
    }) nightly.${testNightly.date}.default;
    rustup-toolchain-beta-date = assertEq (fromRustupToolchain {
      channel = "beta-${testBeta.date}";
    }) beta.${testBeta.date}.default;
    rustup-toolchain-customization =
      assertEq
        (fromRustupToolchain {
          channel = "1.51.0";
          components = [
            "rustfmt"
            "rustc-dev"
          ];
          targets = [
            "wasm32-unknown-unknown"
            "aarch64-unknown-linux-gnu"
          ];
        })
        (
          stable."1.51.0".default.override {
            extensions = [
              "rustfmt"
              "rustc-dev"
            ];
            targets = [
              "wasm32-unknown-unknown"
              "aarch64-unknown-linux-gnu"
            ];
          }
        );

    rustup-toolchain-profile-missing =
      assertEq
        (tryEval (fromRustupToolchain {
          channel = "1.51.0";
          profile = "non_existent";
        })).success
        false;
    rustup-toolchain-profile-too-early =
      assertEq
        (tryEval (fromRustupToolchain {
          channel = "1.29.0";
          profile = "minimal";
        })).success
        false;
    rustup-toolchain-profile-fallback = assertEq (fromRustupToolchain {
      channel = "1.29.0";
    }) stable."1.29.0".rust;

    rustup-toolchain-file-toml =
      assertEq
        (fromRustupToolchainFile (
          toFile "rust-toolchain-toml" ''
            [toolchain]
            channel = "nightly-${testNightly.date}"
            components = [ "rustfmt", "rustc-dev" ]
            targets = [ "wasm32-unknown-unknown", "aarch64-unknown-linux-gnu" ]
          ''
        ))
        (
          nightly.${testNightly.date}.default.override {
            extensions = [
              "rustfmt"
              "rustc-dev"
            ];
            targets = [
              "wasm32-unknown-unknown"
              "aarch64-unknown-linux-gnu"
            ];
          }
        );
    rustup-toolchain-file-legacy = assertEq (fromRustupToolchainFile (
      toFile "rust-toolchain-legacy" ''
        nightly-${testNightly.date}
      ''
    )) nightly.${testNightly.date}.default;
    rustup-toolchain-file-minimal =
      assertEq
        (fromRustupToolchainFile (
          toFile "rust-toolchain-minimal" ''
            [toolchain]
            channel = "nightly-${testNightly.date}"
            profile = "minimal"
            components = [ "rustfmt", "rustc-dev" ]
            targets = [ "aarch64-unknown-linux-gnu" ]
          ''
        ))
        (
          nightly.${testNightly.date}.minimal.override {
            extensions = [
              "rustfmt"
              "rustc-dev"
            ];
            targets = [ "aarch64-unknown-linux-gnu" ];
          }
        );

    latest-nightly-default = rust-bin.selectLatestNightlyWith (toolchain: toolchain.default);

    # Darwin specific tests.
  }
// optionalAttrs (system == "aarch64-darwin") {
  url-forward =
    assertUrl nightly.${testNightly.date}.rust-docs
      "https://static.rust-lang.org/dist/${testNightly.date}/rust-docs-nightly-x86_64-apple-darwin.tar.xz";
  aarch64-darwin-use-x86-docs = rust-bin.stable."1.51.0".default.override {
    targets = [ "x86_64-apple-darwin" ];
    targetExtensions = [ "rust-docs" ];
  };
}
