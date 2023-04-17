final: prev:
(import ./rust-overlay.nix final) (prev // (import ./manifest.nix final prev))
