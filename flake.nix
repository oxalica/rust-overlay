{
  description = ''
    Pure and reproducible overlay for binary distributed rust toolchains.
    A compatible but better replacement for rust overlay of github:mozilla/nixpkgs-mozilla.
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }@inputs:
    let
      inherit (nixpkgs) lib;
      inherit (lib) filterAttrs mapAttrs' replaceStrings;

      forEachSystem = lib.genAttrs lib.systems.flakeExposed;

      overlay = import ./.;

      defaultDistRoot = import ./lib/dist-root.nix;
      mkManifests = distRoot: import ./lib/manifests.nix { inherit lib distRoot; };

      # Builder to construct `rust-bin` interface on an existing `pkgs`.
      # This would be immutable, non-intrusive and (hopefully) can benefit from
      # flake eval-cache.
      #
      # Note that this does not contain compatible attrs for mozilla-overlay.
      mkRustBin =
        {
          distRoot ? defaultDistRoot,
        }:
        pkgs:
        lib.fix (
          rust-bin:
          import ./lib/rust-bin.nix {
            inherit lib pkgs;
            inherit (pkgs.rust) toRustTarget;
            inherit (rust-bin) nightly;
            manifests = mkManifests distRoot;
          }
        );

    in
    {
      lib = {
        # Internal use only!
        _internal = {
          defaultManifests = mkManifests defaultDistRoot;
        };

        inherit mkRustBin;
      };

      overlays = {
        default = overlay;
        rust-overlay = overlay;
      };

      # TODO: Flake outputs except `overlay[s]` are not stabilized yet.

      packages =
        let
          select =
            version: comps:
            if comps ? default then
              comps.default // { minimal = comps.minimal or (throw "missing profile 'minimal' for ${version}"); }
            else
              null;
          result =
            rust-bin:
            mapAttrs' (version: comps: {
              name = if version == "latest" then "rust" else "rust_${replaceStrings [ "." ] [ "_" ] version}";
              value = select version comps;
            }) rust-bin.stable
            // mapAttrs' (version: comps: {
              name = if version == "latest" then "rust-nightly" else "rust-nightly_${version}";
              value = select version comps;
            }) rust-bin.nightly
            // mapAttrs' (version: comps: {
              name = if version == "latest" then "rust-beta" else "rust-beta_${version}";
              value = select version comps;
            }) rust-bin.beta;
          result' = rust-bin: filterAttrs (name: drv: drv != null) (result rust-bin);
        in
        forEachSystem (
          system:
          result' (mkRustBin { } nixpkgs.legacyPackages.${system})
          // {
            default = self.packages.${system}.rust;
          }
        );

      checks = forEachSystem (import ./tests inputs);
    };
}
