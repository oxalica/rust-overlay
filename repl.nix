# For test only.
import <nixpkgs> {
  overlays = [ (import ./.) ];
}
