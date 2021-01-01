final: prev:
let
  inherit (prev.lib) filter hasAttr attrNames mapAttrs concatMap mapAttrs' replaceStrings;

  targets = import ./manifests/targets.nix // { _ = "*"; };

  distServer = "https://static.rust-lang.org";

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

  # version -> { pkgName = { _1 = "..."; } } -> { pkgName = { x86_64-unknown-linux-gnu = fetchurl { .. }; } }
  uncompressManifest = version: { date, ... }@manifest: rec {
    inherit date;
    pkg =
      mapAttrs (pkgName: { v, ... }@hashes: {
        version = v;
        target =
          mapAttrs' (targetIdx: hash: let
            target = targets.${targetIdx};
            pkgNameStripped = replaceStrings ["-preview"] [""] pkgName;
            targetTail = if targetIdx == "_" then "" else "-" + target;
          in {
            name = target;
            value = {
              xz_url = "${distServer}/dist/${date}/${pkgNameStripped}-${version}${targetTail}.tar.xz";
              xz_hash = hash;
            } // (if pkgName == "rust" then rustPkgExtra pkg target else {});
          }) (removeAttrs hashes ["v"]);
      }) (removeAttrs manifest ["date"]);
  };

  uncompressManifestSet = set: let
    ret = mapAttrs uncompressManifest (removeAttrs set ["latest"]);
  in ret // { latest = ret.${set.latest}; };

  manifests = {
    stable = uncompressManifestSet (import ./manifests/stable);
  };

# in { inherit manifests; }
in import ./rust-overlay.nix final prev manifests
