with import <nixpkgs> {
  crossSystem = "aarch64-linux";
  overlays = [ (import ../..) ];
};
mkShell {
  nativeBuildInputs = [
    # Manual `buildPackages` is required here. See: https://github.com/NixOS/nixpkgs/issues/49526
    # build = host = x86_64, target = aarch64
    buildPackages.rust-bin.stable.latest.minimal
    buildPackages.pkg-config
    # build = host = target = x86_64, just to avoid re-build.
    pkgsBuildBuild.qemu
  ];
  buildInputs = [
    # build = x86_64, host = target = aarch64
    openssl
  ];
}
