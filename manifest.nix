final: prev:
with (prev.lib);
with builtins;
let
  targets = import ./manifests/targets.nix // { _ = "*"; };
  renamesList = import ./manifests/renames.nix;

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
  uncompressManifest = nightly: version: {
    v, # rustc version
    d, # date
    r, # rename index
    ...
  }@manifest: rec {
    date = d;
    renames = mapAttrs (from: to: { inherit to; }) (elemAt renamesList r);
    pkg =
      mapAttrs (pkgName: { u ? null /* url version */, ... }@hashes: {
        # We use rustc version for all components to reduce manifest size.
        # This version is just used for component derivation name.
        version = "${v} (000000000 ${d})"; # "<version> (<commit-hash> yyyy-mm-dd)"
        target =
          mapAttrs' (targetIdx: hash: let
            target = targets.${targetIdx};
            pkgNameStripped = removeSuffix "-preview" pkgName;
            targetTail = if targetIdx == "_" then "" else "-" + target;
            urlVersion =
              if u != null then u             # Use specified url version if exists.
              else if nightly then "nightly"  # Otherwise, for nightly channel, default to be "nightly".
              else v;                         # For stable channel, default to be rustc version.
          in {
            name = target;
            value = {
              xz_url = "${distRoot}/${date}/${pkgNameStripped}-${urlVersion}${targetTail}.tar.xz";
              xz_hash = hash;
            } // (if pkgName == "rust" then rustPkgExtra pkg target else {});
          }) (removeAttrs hashes ["u"]);
      }) (removeAttrs manifest ["v" "d" "r"]);
  };

  uncompressManifestSet = nightly: set: let
    ret = mapAttrs (uncompressManifest nightly) (removeAttrs set ["latest"]);
  in ret // { latest = ret.${set.latest}; };

in {
  rust-bin = (prev.rust-bin or {}) // {
    # The dist url for fetching.
    # Override it if you want to use a mirror server.
    distRoot = "https://static.rust-lang.org/dist";

    # For internal usage.
    manifests = {
      stable = uncompressManifestSet false (import ./manifests/stable);
      nightly = uncompressManifestSet true (import ./manifests/nightly);
    };
  };
}
