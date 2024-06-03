# Overlay interface for non-flake Nix.
final: prev:
let
  inherit (builtins) mapAttrs readFile;

  inherit (final) lib rust-bin;
  inherit (rust-bin._internal) toolchainFromManifest selectManifest;

  # Same as `toolchainFromManifest` but read from a manifest file.
  toolchainFromManifestFile = path: toolchainFromManifest (fromTOML (readFile path));

  # Override all pkgs of a toolchain set.
  overrideToolchain = attrs: mapAttrs (name: pkg: pkg.override attrs);

  # This is eagerly evaluated and disallow overriding. Get this from `final`
  # will easily encounter infinite recursion without manually expand all attrs
  # from `rust-bin.nix` output like `mkIf` does.
  # This is considered internal anyway.
  manifests = import ./lib/manifests.nix {
    inherit lib;
    inherit (rust-bin) distRoot;
  };

in {
  rust-bin = (prev.rust-bin or { }) // {
    # The overridable dist url for fetching.
    distRoot = import ./lib/dist-root.nix;
  } // import ./lib/rust-bin.nix {
    inherit lib manifests;
    inherit (final.rust) toRustTarget;
    inherit (rust-bin) nightly;
    pkgs = final;
  };

  # All attributes below are for compatibility with mozilla overlay.

  lib = (prev.lib or { }) // {
    rustLib = (prev.lib.rustLib or { }) // {
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
      fromManifestFile = manifestFilePath: { stdenv, fetchurl, patchelf }@deps: builtins.trace ''
        `fromManifestFile` is deprecated.
        Select a toolchain from `rust-bin` or using `rustChannelOf` instead.
        See also README at https://github.com/oxalica/rust-overlay
      '' (overrideToolchain deps (toolchainFromManifestFile manifestFilePath));
    };
  };

  rustChannelOf = manifestArgs: toolchainFromManifest (selectManifest manifestArgs);

  latest = (prev.latest or {}) // {
    rustChannels = {
      stable = rust-bin.stable.latest;
      beta = rust-bin.beta.latest;
      nightly = rust-bin.nightly.latest;
    };
  };

  rustChannelOfTargets = channel: date: targets:
    (final.rustChannelOf { inherit channel date; })
      .rust.override { inherit targets; };

  rustChannels = final.latest.rustChannels;
}
