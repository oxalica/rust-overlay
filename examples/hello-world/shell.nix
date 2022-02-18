{ channel ? "stable", profile ? "default" }:
with import <nixpkgs> { overlays = [ (import ../..) ]; };
mkShell {
  nativeBuildInputs = [
    (if channel == "nightly" then
      rust-bin.selectLatestNightlyWith (toolchain: toolchain.${profile})
    else
      rust-bin.${channel}.latest.${profile})
  ];
}
