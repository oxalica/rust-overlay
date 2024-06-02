# Define component resolution and utility functions.
self: super:

let
  inherit (builtins) compareVersions fromTOML match readFile tryEval;

  inherit (self.lib)
    any attrNames attrValues concatStringsSep elem elemAt filter flatten foldl'
    hasPrefix head isString length listToAttrs makeOverridable mapAttrs
    mapAttrsToList optional optionalAttrs replaceStrings substring trace unique;

  # Remove keys from attrsets whose value is null.
  removeNulls = set:
    removeAttrs set
      (filter (name: set.${name} == null)
        (attrNames set));

  # FIXME: https://github.com/NixOS/nixpkgs/pull/146274
  toRustTarget = platform:
    if platform.isWasi then
      "${platform.parsed.cpu.name}-wasi"
    else
      platform.rust.rustcTarget or (super.rust.toRustTarget platform);

  # The platform where `rustc` is running.
  rustHostPlatform = toRustTarget self.stdenv.hostPlatform;
  # The platform of binary which `rustc` produces.
  rustTargetPlatform = toRustTarget self.stdenv.targetPlatform;

  mkComponentSet = self.callPackage ./mk-component-set.nix {
    inherit toRustTarget removeNulls;
  };

  mkAggregated = self.callPackage ./mk-aggregated.nix {};

  # Manifest selector.
  selectManifest = { channel, date ? null }: let
    inherit (self.rust-bin) manifests;

    assertWith = cond: msg: body: if cond then body else throw msg;

    # https://rust-lang.github.io/rustup/concepts/toolchains.html#toolchain-specification
    # <channel> = stable|beta|nightly|<major.minor>|<major.minor.patch>

    asVersion = match "[0-9]+\\.[0-9]+(\\.[0-9]+)?" channel;
    asNightlyDate = let m = match "nightly-([0-9]+-[0-9]+-[0-9]+)" channel; in
      if m == null then null else elemAt m 0;
    asBetaDate = let m = match "beta-([0-9]+-[0-9]+-[0-9]+)" channel; in
      if m == null then null else elemAt m 0;

    maxWith = zero: f: foldl' (lhs: rhs: if lhs == zero || f lhs rhs < 0 then rhs else lhs) zero;

    latestStableWithMajorMinor =
      maxWith "" compareVersions
        (filter (hasPrefix (channel + "."))
          (attrNames manifests.stable));

  in
    # "stable"
    if channel == "stable" then
      assertWith (date == null) "Stable version with specific date is not supported"
        manifests.stable.latest
    # "nightly"
    else if channel == "nightly" then
      manifests.nightly.${if date != null then date else "latest"} or (throw "Nightly ${date} is not available")
    # "beta"
    else if channel == "beta" then
      manifests.beta.${if date != null then date else "latest"} or (throw "Beta ${date} is not available")
    # "1.49.0" or "1.49"
    else if asVersion != null then
      assertWith (date == null) "Stable version with specific date is not supported" (
        # "1.49"
        if asVersion == [ null ] then
          manifests.stable.${latestStableWithMajorMinor} or (throw "No stable ${channel}.* is available")
        # "1.49.0"
        else
          manifests.stable.${channel} or (throw "Stable ${channel} is not available"))
    # "beta-2021-01-01"
    else if asBetaDate != null then
      assertWith (date == null) "Cannot specify date in both `channel` and `date`"
        manifests.beta.${asBetaDate} or (throw "Beta ${asBetaDate} is not available")
    # "nightly-2021-01-01"
    else if asNightlyDate != null then
      assertWith (date == null) "Cannot specify date in both `channel` and `date`"
        manifests.nightly.${asNightlyDate} or (throw "Nightly ${asNightlyDate} is not available")
    # Otherwise
    else throw "Unknown channel: ${channel}";

  # Select a toolchain and aggregate components by rustup's `rust-toolchain` file format.
  # See: https://rust-lang.github.io/rustup/concepts/profiles.html
  # Or see source: https://github.com/rust-lang/rustup/blob/84974df1387812269c7b29fa5f3bb1c6480a6500/doc/src/overrides.md#the-toolchain-file
  fromRustupToolchain = { path ? null, channel ? null, profile ? null, components ? [], targets ? [] }:
    if path != null then throw "`path` is not supported, please directly add it to your PATH instead"
    else if channel == null then throw "`channel` is required"
    else
      let
        toolchain = toolchainFromManifest (selectManifest { inherit channel; });
        profile' = if profile == null then "default" else profile;
        pkg =
          if toolchain._profiles != {} then
            toolchain._profiles.${profile'} or (throw ''
              Rust ${toolchain._version} doesn't have profile `${profile'}`.
              Available profiles are: ${concatStringsSep ", " (attrNames toolchain._profiles)}
            '')
          # Fallback to package `rust` when profiles are not supported and not specified.
          else if profile == null then
            toolchain.rust
          else
            throw "Cannot select profile `${profile'}` since rust ${toolchain._version} is too early to support profiles";
      in pkg.override {
        extensions = components;
        inherit targets;
      };

  # Same as `fromRustupToolchain` but read from a `rust-toolchain` file (legacy one-line string or in TOML).
  fromRustupToolchainFile = path: let
    content = readFile path;
    legacy = match "([^\r\n]+)\r?\n?" content;
  in if legacy != null
    then fromRustupToolchain { channel = head legacy; }
    else fromRustupToolchain (fromTOML content).toolchain;

  mkComponentSrc = { url, sha256 }:
    let
      url' = replaceStrings [" "] ["%20"] url; # This is required or download will fail.
      # Filter names like `llvm-tools-1.34.2 (6c2484dc3 2019-05-13)-aarch64-unknown-linux-gnu.tar.xz`
      matchParenPart = match ".*/([^ /]*) [(][^)]*[)](.*)" url;
      name = if matchParenPart == null then "" else (elemAt matchParenPart 0) + (elemAt matchParenPart 1);
    in
      self.fetchurl { inherit name sha256; url = url'; };

  # Resolve final components to install from mozilla-overlay style `extensions`, `targets` and `targetExtensions`.
  #
  # `componentSet` has a layout of `componentSet.<name>.<rust-target> : Derivation`.
  # `targetComponentsList` is a list of all component names for target platforms.
  # `name` is only used for error message.
  #
  # Returns a list of component derivations, or throw if failed.
  resolveComponents =
    { name
    , componentSet
    , allComponentSet
    , allPlatformSet
    , targetComponentsList
    , profileComponents
    , extensions
    , targets
    , targetExtensions
    }:
    let
      # Components for target platform like `rust-std`.
      collectTargetComponents = allowMissing: name:
        let
          targetSelected = flatten (map (tgt: componentSet.${tgt}.${name} or []) targets);
        in if !allowMissing -> targetSelected != [] then
          targetSelected
        else
          "Component `${name}` doesn't support any of targets: ${concatStringsSep ", " targets}";

      collectComponents = allowMissing: name:
        if elem name targetComponentsList then
          collectTargetComponents allowMissing name
        else
          # Components for host platform like `rustc`.
          componentSet.${rustHostPlatform}.${name} or (
            if allowMissing then []
            else "Host component `${name}` doesn't support `${rustHostPlatform}`");

      # Profile components can be skipped silently when missing.
      # Eg. `rust-mingw` on non-Windows platforms, or `rust-docs` on non-tier1 platforms.
      result =
        flatten (map (collectComponents true) profileComponents) ++
        flatten (map (collectComponents false) extensions) ++
        flatten (map (collectTargetComponents false) targetExtensions);

      isTargetUnused = target:
        !any (name: componentSet ? ${target}.${name})
          # FIXME: Get rid of the legacy component `rust`.
          (filter (name: name == "rust" || elem name targetComponentsList)
            (profileComponents ++ extensions)
          ++ targetExtensions);

      # Fail-fast for typo in `targets`, `extensions`, `targetExtensions`.
      fastErrors =
        flatten (
          map (tgt: optional (!(allPlatformSet ? ${tgt}))
            "Unknown target `${tgt}`, typo or not supported by this version?")
            targets ++
          map (name: optional (!(allComponentSet ? ${name}))
            "Unknown component `${name}`, typo or not support by this version?")
            (profileComponents ++ extensions ++ targetExtensions));

      errors =
        if fastErrors != [] then
          fastErrors
        else
          filter isString result ++
          map (tgt: "Target `${tgt}` is not supported by any components or extensions")
            (filter isTargetUnused targets);

      notes = [
        "note: profile components: ${toString profileComponents}"
      ] ++ optional (targets != []) "note: selected targets: ${toString targets}"
      ++ optional (extensions != []) "note: selected extensions: ${toString extensions}"
      ++ optional (targetExtensions != []) "note: selected targetExtensions: ${toString targetExtensions}"
      ++ flatten (map (platform:
        optional (componentSet ? ${platform})
          "note: components available for ${platform}: ${toString (attrNames componentSet.${platform})}"
        ) (unique ([ rustHostPlatform ] ++ targets)))
      ++ [
        ''
          note: check here to see all targets and which components are available on each targets:
                https://rust-lang.github.io/rustup-components-history
        ''
      ];

    in
      if errors == [] then result
      else throw ''
        Component resolution failed for ${name}
        ${concatStringsSep "\n" (errors ++ notes)}
      '';

  # Genereate the toolchain set from a parsed manifest.
  #
  # Manifest files are organized as follow:
  # { date = "2017-03-03";
  #   pkg.cargo.version= "0.18.0-nightly (5db6d64 2017-03-03)";
  #   pkg.cargo.target.x86_64-unknown-linux-gnu = {
  #     available = true;
  #     hash = "abce..."; # sha256
  #     url = "https://static.rust-lang.org/dist/....tar.gz";
  #     xz_hash = "abce..."; # sha256
  #     xz_url = "https://static.rust-lang.org/dist/....tar.xz";
  #   };
  # }
  #
  # The packages available usually are:
  #   cargo, rust-analysis, rust-docs, rust-src, rust-std, rustc, and
  #   rust, which aggregates them in one package.
  #
  # For each package the following options are available:
  #   extensions        - The extensions that should be installed for the package.
  #                       For example, install the package rust and add the extension rust-src.
  #   targets           - The package will always be installed for the host system, but with this option
  #                       extra targets can be specified, e.g. "mips-unknown-linux-musl". The target
  #                       will only apply to components of the package that support being installed for
  #                       a different architecture. For example, the rust package will install rust-std
  #                       for the host system and the targets.
  #   targetExtensions  - If you want to force extensions to be installed for the given targets, this is your option.
  #                       All extensions in this list will be installed for the target architectures.
  #                       *Attention* If you want to install an extension like rust-src, that has no fixed architecture (arch *),
  #                       you will need to specify this extension in the extensions options or it will not be installed!
  toolchainFromManifest = manifest: let
    maybeRename = name: manifest.renames.${name}.to or name;

    # platform -> true
    # For fail-fast test.
    allPlatformSet =
      listToAttrs (
        flatten (
          mapAttrsToList (compName: { target, ... }:
            map (platform: { name = platform; value = true; })
              (attrNames target)
          ) manifest.pkg));

    # componentName -> true
    # May also contains unavailable components. Just for fail-fast test.
    allComponentSet =
      mapAttrs (compName: _: true)
        (manifest.pkg // manifest.renames);

    # componentSet.x86_64-unknown-linux-gnu.cargo = <derivation>;
    componentSet =
      mapAttrs (platform: _:
        mkComponentSet {
          inherit (manifest) version renames;
          inherit platform;
          srcs = removeNulls
            (mapAttrs (compName: { target, ... }:
              let content = target.${platform} or target."*" or null; in
              if content == null then
                null
              else
                mkComponentSrc {
                  url = content.xz_url;
                  sha256 = content.xz_hash;
                }
            ) manifest.pkg);
        }
      ) allPlatformSet;

    mkProfile = name: profileComponents:
      makeOverridable ({ extensions, targets, targetExtensions }:
        mkAggregated {
          pname = "rust-${name}";
          inherit (manifest) version date;
          availableComponents = componentSet.${rustHostPlatform};
          selectedComponents = resolveComponents {
            name = "rust-${name}-${manifest.version}";
            inherit allPlatformSet allComponentSet componentSet profileComponents targetExtensions;
            inherit (manifest) targetComponentsList;
            extensions = extensions;
            targets = unique ([
              rustHostPlatform # Build script requires host std.
              rustTargetPlatform
            ] ++ targets);
          };
        }
      ) {
        extensions = [];
        targets = [];
        targetExtensions = [];
      };

    profiles = mapAttrs mkProfile manifest.profiles;

    result =
      # Individual components.
      componentSet.${rustHostPlatform} //
      # Profiles.
      profiles // {
        # Legacy support for special pre-aggregated package.
        # It has more components than `default` profile but less than `complete` profile.
        rust =
          let
            pkg = mkProfile "legacy" [ "rust" ];
          in if profiles != {} then
            trace ''
              Rust ${manifest.version}:
              Pre-aggregated package `rust` is not encouraged for stable channel since it contains almost all and uncertain components.
              Consider use `default` profile like `rust-bin.stable.latest.default` and override it with extensions you need.
              See README for more information.
            '' pkg
          else
            pkg;
      };

  in
    # If the platform is not supported for the current version, return nothing here,
    # so others can easily check it by `toolchain ? default`.
    optionalAttrs (componentSet ? ${rustHostPlatform}) result //
    {
      # Internal use.
      _components = componentSet;
      _profiles = profiles;
      _version = manifest.version;
      _manifest = manifest;
    };

  # Same as `toolchainFromManifest` but read from a manifest file.
  toolchainFromManifestFile = path: toolchainFromManifest (fromTOML (readFile path));

  # Override all pkgs of a toolchain set.
  overrideToolchain = attrs: mapAttrs (name: pkg: pkg.override attrs);

  # From a git revision of rustc.
  # This does the same thing as crate `rustup-toolchain-install-master`.
  # But you need to manually provide component hashes.
  fromRustcRev = {
    # Package name of the derivation.
    pname ? "rust-custom",
    # Git revision of rustc.
    rev,
    # Version of the built package.
    version ? substring 0 7 rev,
    # Attrset with component name as key and its SRI hash as value.
    components,
    # Rust target to download.
    target ? rustTargetPlatform
  }: let
    hashToSrc = compName: hash:
      self.fetchurl {
        url = if compName == "rust-src"
          then "https://ci-artifacts.rust-lang.org/rustc-builds/${rev}/${compName}-nightly.tar.xz"
          else "https://ci-artifacts.rust-lang.org/rustc-builds/${rev}/${compName}-nightly-${target}.tar.xz";
        inherit hash;
      };
    components' = mkComponentSet {
      inherit version;
      platform = target;
      srcs = mapAttrs hashToSrc components;
    };
  in
    mkAggregated {
      inherit pname version;
      date = null;
      selectedComponents = attrValues components';
    };

  # Select latest nightly toolchain which makes selected profile builds.
  # Some components are missing in some nightly releases.
  # Usage:
  # `selectLatestNightlyWith (toolchain: toolchain.default.override { extensions = ["llvm-tools-preview"]; })`
  selectLatestNightlyWith = selector:
    let
      nightlyDates = attrNames (removeAttrs self.rust-bin.nightly [ "latest" ]);
      dateLength = length nightlyDates;
      go = idx:
        let ret = selector (self.rust-bin.nightly.${elemAt nightlyDates idx}); in
        if idx == 0 then
          ret
        else if dateLength - idx >= 256 then
          trace "Failed to select nightly version after 100 tries" ret
        else if ret != null && (tryEval ret.drvPath).success then
          ret
        else
          go (idx - 1);
    in
      go (length nightlyDates - 1);

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
    (super.rust-bin or {}) //
    mapAttrs (channel: mapAttrs (version: toolchainFromManifest)) super.rust-bin.manifests //
    {
      inherit fromRustupToolchain fromRustupToolchainFile;
      inherit selectLatestNightlyWith;
      inherit fromRustcRev;
    };

  # All attributes below are for compatiblity with mozilla overlay.

  lib = (super.lib or {}) // {
    rustLib = (super.lib.rustLib or {}) // {
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

  latest = (super.latest or {}) // {
    rustChannels = {
      stable = self.rust-bin.stable.latest;
      beta = self.rust-bin.beta.latest;
      nightly = self.rust-bin.nightly.latest;
    };
  };

  rustChannelOfTargets = channel: date: targets:
    (self.rustChannelOf { inherit channel date; })
      .rust.override { inherit targets; };

  rustChannels = self.latest.rustChannels;
}
