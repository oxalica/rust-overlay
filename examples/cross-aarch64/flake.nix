# Example flake for `nix develop`.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      rust-overlay,
      nixpkgs,
    }:
    {
      devShells.x86_64-linux.default =
        let
          pkgsCross = nixpkgs.legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform;
          rust-bin = rust-overlay.lib.mkRustBin { } pkgsCross.buildPackages;
        in
        pkgsCross.callPackage (
          {
            mkShell,
            pkg-config,
            qemu,
            openssl,
            stdenv,
          }:
          mkShell {
            nativeBuildInputs = [
              rust-bin.stable.latest.minimal
              pkg-config
            ];

            depsBuildBuild = [ qemu ];
            buildInputs = [ openssl ];

            env = {
              CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER = "${stdenv.cc.targetPrefix}cc";
              CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUNNER = "qemu-aarch64";
            };
          }
        ) { };
    };
}
