# For test.
with import <nixpkgs> {
  overlays = [ (import ./.) ];
}; {
  stable = lib.mapAttrs
    (channel: _: (rustChannelOf { inherit channel; }).rust)
    (removeAttrs (import ./manifests/stable) ["latest"]);
  nightly = lib.mapAttrs
    (date: _: (rustChannelOf { channel = "nightly"; inherit date; }).rust)
    (removeAttrs (import ./manifests/nightly) ["latest"]);
}
