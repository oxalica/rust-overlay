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
  uncompressManifest = nightly: version: { date /* date */, r /* rename index */, ... }@manifest: rec {
    inherit date;
    renames = mapAttrs (from: to: { inherit to; }) (elemAt renamesList r);
    pkg =
      mapAttrs (pkgName: { v /* pkg version */, k ? 0 /* url kind */, ... }@hashes: {
        version = v;
        target =
          mapAttrs' (targetIdx: hash: let
            target = targets.${targetIdx};
            pkgNameStripped = removeSuffix "-preview" pkgName;
            targetTail = if targetIdx == "_" then "" else "-" + target;
            vHead = head (match "([^ ]*) .*" v);
            urlVersion =
              if nightly then "nightly"     # 'nightly'
              else if k == 0 then vHead     # '0.44.1 (aaaaaaaaa 2018-01-01)' -> '0.44.1' [package version]
              else if k == 1 then v         # '0.44.1 (aaaaaaaaa 2018-01-01)' [package version]
              else if k == 2 then version   # '1.49.0' [stable toolchain version]
              else throw "Invalid k";
          in {
            name = target;
            value = {
              xz_url = "${distRoot}/${date}/${pkgNameStripped}-${urlVersion}${targetTail}.tar.xz";
              xz_hash = hash;
            } // (if pkgName == "rust" then rustPkgExtra pkg target else {});
          }) (removeAttrs hashes ["v" "k"]);
      }) (removeAttrs manifest ["date" "r"]);
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
