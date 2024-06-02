final: prev:
(import ./lib/rust-bin.nix final) (prev // (import ./lib/manifests.nix final prev))
