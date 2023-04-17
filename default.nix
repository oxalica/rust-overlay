# The overlay.
final: prev:
let
  inherit (builtins) mapAttrs trace;

  manifests = import ./manifest.nix {
    inherit (final) lib;
    inherit (final.rust-bin) distRoot;
  };

  inherit (import ./lib.nix { inherit (final) lib pkgs rust-bin; })
    fromRustcRev
    fromRustupToolchain
    fromRustupToolchainFile
    overrideToolchain
    selectLatestNightlyWith
    selectManifest
    toolchainFromManifest
    toolchainFromManifestFile
    ;

in {
  # For each channel:
  #   rust-bin.stable.latest.{minimal,default,complete} # Profiles.
  #   rust-bin.stable.latest.rust   # Pre-aggregate from upstream.
  #   rust-bin.stable.latest.cargo  # Components...
  #   rust-bin.stable.latest.rustc
  #   rust-bin.stable.latest.rust-docs
  #   ...
  #
  # For a specific version of stable:
  #   rust-bin.stable."1.47.0".default
  #
  # For a specific date of beta:
  #   rust-bin.beta."2021-01-01".default
  #
  # For a specific date of nightly:
  #   rust-bin.nightly."2020-01-01".default
  rust-bin =
    (prev.rust-bin or {}) //
    mapAttrs (channel: mapAttrs (version: toolchainFromManifest)) manifests //
    {
      # The dist url for fetching.
      # Override it if you want to use a mirror server.
      distRoot = "https://static.rust-lang.org/dist";

      inherit fromRustupToolchain fromRustupToolchainFile;
      inherit selectLatestNightlyWith;
      inherit fromRustcRev;

      # For internal usage.
      inherit manifests;
    };

  # All attributes below are for compatiblity with mozilla overlay.

  lib = (prev.lib or {}) // {
    rustLib = (prev.lib.rustLib or {}) // {
      manifest_v2_url = throw ''
        `manifest_v2_url` is not supported.
        Select a toolchain from `rust-bin` or using `rustChannelOf` instead.
        See also README at https://github.com/oxalica/rust-overlay
      '';
      fromManifest = throw ''
        `fromManifest` is not supported due to network access during evaluation.
        Select a toolchain from `rust-bin` or using `rustChannelOf` instead.
        See also README at https://github.com/oxalica/rust-overlay
      '';
      fromManifestFile = manifestFilePath: { stdenv, fetchurl, patchelf }@deps: trace ''
        `fromManifestFile` is deprecated.
        Select a toolchain from `rust-bin` or using `rustChannelOf` instead.
        See also README at https://github.com/oxalica/rust-overlay
      '' (overrideToolchain deps (toolchainFromManifestFile manifestFilePath));
    };
  };

  rustChannelOf = manifestArgs: toolchainFromManifest (selectManifest manifestArgs);

  latest = (prev.latest or {}) // {
    rustChannels = {
      stable = final.rust-bin.stable.latest;
      beta = final.rust-bin.beta.latest;
      nightly = final.rust-bin.nightly.latest;
    };
  };

  rustChannelOfTargets = channel: date: targets:
    (final.rustChannelOf { inherit channel date; })
      .rust.override { inherit targets; };

  rustChannels = final.latest.rustChannels;
}
