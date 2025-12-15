# Manifests which describe the content of each version.
{
  lib,
  distRoot,
  src,
}:
let
  inherit (builtins) match isString toString;

  inherit (lib)
    attrNames
    concatMap
    elemAt
    filter
    hasAttr
    mapAttrs
    mapAttrs'
    removeSuffix
    ;

  targets = import (src + "/manifests/targets.nix") // {
    _ = "*";
  };
  renamesList = import (src + "/manifests/renames.nix");
  profilesList = import (src + "/manifests/profiles.nix");

  # Extensions for mixed `rust` pkg.
  components = [
    "rustc"
    "rust-std"
    "cargo"
  ];
  singleTargetExtensions = [
    "clippy-preview"
    "miri-preview"
    "rls-preview"
    "rust-analyzer-preview"
    "rustfmt-preview"
    "llvm-tools-preview"
    "rust-analysis"
  ];
  multiTargetExtensions = [
    "rust-std"
    "rustc-dev"
    "rustc-docs"
    "rust-src" # This has only one special target `*`
  ];
  rustPkgExtra =
    pkgs: target:
    let
      singleTargetTups = map (pkg: { inherit pkg target; }) (
        filter (p: hasAttr p pkgs && hasAttr target pkgs.${p}.target) singleTargetExtensions
      );
      multiTargetTups = concatMap (
        pkg: map (target: { inherit pkg target; }) (attrNames pkgs.${pkg}.target)
      ) (filter (p: hasAttr p pkgs) multiTargetExtensions);
    in
    {
      components = map (pkg: { inherit pkg target; }) components;
      extensions = singleTargetTups ++ multiTargetTups;
    };

  # Uncompress the compressed manifest to the original one
  # (not complete but has enough information to make up the toolchain).
  uncompressManifest =
    channel: version:
    {
      v, # Rustc version
      d, # Date
      r, # Renames index
      p ? null, # Profiles index
      ...
    }@manifest:
    rec {

      # Version used for derivation.
      version =
        if match ".*(nightly|beta).*" v != null then
          "${v}-${d}" # 1.51.0-nightly-2021-01-01, 1.52.0-beta.2-2021-03-27
        else
          v; # 1.51.0

      date = d;
      renames = mapAttrs (from: to: { inherit to; }) (elemAt renamesList r);

      pkg =
        mapAttrs
          (
            pkgName:
            {
              # Version appears in URL
              u ? null,
              ...
            }@hashes:
            {
              # We use rustc version for all components to reduce manifest size.
              # This version is just used for component derivation name.
              version = "${v} (000000000 ${d})"; # "<version> (<commit-hash> yyyy-mm-dd)"
              target =
                let
                  results = mapAttrs' (
                    targetIdx: hash:
                    let
                      target = targets.${targetIdx};
                      pkgNameStripped = removeSuffix "-preview" pkgName;
                      targetTail = if targetIdx == "_" then "" else "-" + target;
                      urlVersion =
                        if u != null then
                          u # Use specified version for URL if exists.
                        else if channel == "stable" then
                          v # For stable channel, default to be rustc version.
                        else
                          channel; # Otherwise, for beta/nightly channel, default to be "beta"/"nightly".
                    in
                    {
                      name = target;
                      value =
                        # Normally, hash is just the hash.
                        if isString hash then
                          {
                            xz_url = "${distRoot}/${date}/${pkgNameStripped}-${urlVersion}${targetTail}.tar.xz";
                            xz_hash = hash;
                          }
                          // (if pkgName == "rust" then rustPkgExtra pkg target else { })
                        # But hash can be an integer to forward to another URL.
                        # This occurs in aarch64-apple-darwin rust-docs on 2022-02-02.
                        else
                          results.${targets."_${toString hash}"};
                    }
                  ) (removeAttrs hashes [ "u" ]);
                in
                results;
            }
          )
          (
            removeAttrs manifest [
              "v"
              "d"
              "r"
              "p"
            ]
          );

      profiles = if p == null then { } else elemAt profilesList p;

      targetComponentsList = [
        "rust-std"
        "rustc-dev"
        "rustc-docs"
      ];
    };

  uncompressManifestSet =
    channel: set:
    let
      ret = mapAttrs (uncompressManifest channel) (removeAttrs set [ "latest" ]);
    in
    ret // { latest = ret.${set.latest}; };

in
{
  stable = uncompressManifestSet "stable" (import (src + "/manifests/stable"));
  beta = uncompressManifestSet "beta" (import (src + "/manifests/beta"));
  nightly = uncompressManifestSet "nightly" (import (src + "/manifests/nightly"));
}
