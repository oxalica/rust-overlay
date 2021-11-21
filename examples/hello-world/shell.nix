{ profile ? "default" }:
with import <nixpkgs> { overlays = [ (import ../..) ]; };
mkShell {
  nativeBuildInputs = [ rust-bin.stable.latest.${profile} ];
}
