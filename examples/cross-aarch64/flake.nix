# Example flake for `nix develop`.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, rust-overlay, nixpkgs }: {
    devShells.x86_64-linux.default = let
      pkgs = nixpkgs.legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform;
      rust-bin = rust-overlay.lib.mkRustBin { } pkgs.buildPackages;
    in
      pkgs.mkShell {
        nativeBuildInputs = [
          rust-bin.stable.latest.minimal
          pkgs.buildPackages.pkg-config
        ];

        depsBuildBuild = [ pkgs.pkgsBuildBuild.qemu ];
        buildInputs = [ pkgs.openssl ];

        env = {
          CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER = "${pkgs.stdenv.cc.targetPrefix}cc";
          CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUNNER = "qemu-aarch64";
        };
      };
  };
}
