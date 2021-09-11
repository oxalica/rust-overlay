(import <nixpkgs> {
  crossSystem = "aarch64-linux";
  overlays = [ (import ../..) ];
}).callPackage (
{ mkShell, rust-bin, pkg-config, openssl, pkgsBuildBuild }:
mkShell {
  nativeBuildInputs = [
    # Manual `buildPackages` is required here. See: https://github.com/NixOS/nixpkgs/issues/49526
    # build = host = x86_64, target = aarch64
    rust-bin.stable.latest.minimal
    pkg-config

    # build = host = target = x86_64
    # qemu itself is multi-platform and `target` doesn't matter for it.
    # Use build system's to avoid rebuild.
    pkgsBuildBuild.qemu
  ];
  buildInputs = [
    # build = x86_64, host = target = aarch64
    openssl
  ];
}) {}
