# Example flake for `nix develop`.
# See docs/cross_compilation.md for details.
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay, ... }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      overlays = [ (import rust-overlay) ];
      crossSystem.config = "x86_64-w64-mingw32";
    };
  in
  {
    devShells.${system} = {
      default = pkgs.callPackage (
        { mkShell, stdenv, rust-bin, windows, wine64 }:
        mkShell {
          nativeBuildInputs = [
            rust-bin.stable.latest.minimal
          ];

          depsBuildBuild = [ wine64 ];
          buildInputs = [ windows.pthreads ];

          CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "${stdenv.cc.targetPrefix}cc";
          CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUNNER = "wine64";
      }) {};
    };
  };
}
