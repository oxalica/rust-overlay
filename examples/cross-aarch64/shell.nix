# Example flake for `nix shell`.
# See docs/cross_compilation.md for details.
(import <nixpkgs> {
  crossSystem = "aarch64-linux";
  overlays = [ (import ../..) ];
}).callPackage
  (
    {
      mkShell,
      stdenv,
      rust-bin,
      pkg-config,
      openssl,
      qemu,
    }:
    mkShell {
      nativeBuildInputs = [
        rust-bin.stable.latest.minimal
        pkg-config
      ];

      depsBuildBuild = [ qemu ];

      buildInputs = [ openssl ];

      CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER = "${stdenv.cc.targetPrefix}cc";
      CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUNNER = "qemu-aarch64";
    }
  )
  { }
