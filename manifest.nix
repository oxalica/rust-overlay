final: prev:
with (prev.lib);
with builtins;
let
  targets = import ./manifests/targets.nix // { _ = "*"; };
  renamesList = import ./manifests/renames.nix;
  profilesList = import ./manifests/profiles.nix;

  inherit (final.rust-bin) distRoot;

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
  rustPkgExtra = pkgs: target: let
    singleTargetTups = map
      (pkg: { inherit pkg target; })
      (filter (p: hasAttr p pkgs && hasAttr target pkgs.${p}.target) singleTargetExtensions);
    multiTargetTups = concatMap
      (pkg: map (target: { inherit pkg target; }) (attrNames pkgs.${pkg}.target))
      (filter (p: hasAttr p pkgs) multiTargetExtensions);
  in {
    components = map (pkg: { inherit pkg target; }) components;
    extensions = singleTargetTups ++ multiTargetTups;
  };

  # Uncompress the compressed manifest to the original one
  # (not complete but has enough information to make up the toolchain).
  uncompressManifest = channel: version: {
    v,        # Rustc version
    d,        # Date
    r,        # Renames index
    p ? null, # Profiles index
    ...
  }@manifest: rec {

    # Version used for derivation.
    version = if builtins.match ".*(nightly|beta).*" v != null
      then "${v}-${d}"  # 1.51.0-nightly-2021-01-01, 1.52.0-beta.2-2021-03-27
      else v;           # 1.51.0

    date = d;
    renames = mapAttrs (from: to: { inherit to; }) (elemAt renamesList r);

    pkg =
      mapAttrs (pkgName: { u ? null /* Version appears in URL */, ... }@hashes: {
        # We use rustc version for all components to reduce manifest size.
        # This version is just used for component derivation name.
        version = "${v} (000000000 ${d})"; # "<version> (<commit-hash> yyyy-mm-dd)"
        target =
          mapAttrs' (targetIdx: hash: let
            target = targets.${targetIdx};
            pkgNameStripped = removeSuffix "-preview" pkgName;
            targetTail = if targetIdx == "_" then "" else "-" + target;
            urlVersion =
              if u != null then u                     # Use specified version for URL if exists.
              else if channel == "stable" then v      # For stable channel, default to be rustc version.
              else channel;                           # Otherwise, for beta/nightly channel, default to be "beta"/"nightly".
          in {
            name = target;
            value = {
              xz_url = "${distRoot}/${date}/${pkgNameStripped}-${urlVersion}${targetTail}.tar.xz";
              xz_hash = hash;
            } // (if pkgName == "rust" then rustPkgExtra pkg target else {});
          }) (removeAttrs hashes ["u"]);
      }) (removeAttrs manifest ["v" "d" "r" "p"]);

    profiles = if p == null
      then {}
      # `rust-mingw` is in each profile but doesn't support platforms other than Windows.
      else mapAttrs (name: remove "rust-mingw") (elemAt profilesList p);

    targetComponentsList = [
      "rust-std"
      "rustc-dev"
      "rustc-docs"
    ];
  };

  uncompressManifestSet = channel: set: let
    ret = mapAttrs (uncompressManifest channel) (removeAttrs set ["latest"]);
  in ret // { latest = ret.${set.latest}; };

in {
  rust-bin = (prev.rust-bin or {}) // {
    # The dist url for fetching.
    # Override it if you want to use a mirror server.
    distRoot = "https://static.rust-lang.org/dist";

    # For internal usage.
    manifests = {
      stable  = uncompressManifestSet "stable"  (import ./manifests/stable);
      beta    = uncompressManifestSet "beta"    (import ./manifests/beta);
      nightly = uncompressManifestSet "nightly" (import ./manifests/nightly);
    };
  };
}
