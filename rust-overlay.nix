# Modified from: https://github.com/mozilla/nixpkgs-mozilla/blob/8c007b60731c07dd7a052cce508de3bb1ae849b4/rust-overlay.nix

# This file provide a Rust overlay, which provides pre-packaged bleeding edge versions of rustc
# and cargo.
self: super:

let

  # Manifest selector.
  selectManifest = { channel, date ? null }: let
    inherit (self.rust-bin) manifests;
    inherit (builtins) match elemAt;

    assertWith = cond: msg: body: if cond then body else throw msg;

    asVersion = match "[0-9]+\\.[0-9]+\\.[0-9]+" channel;
    asNightlyDate = let m = match "nightly-([0-9]+-[0-9]+-[0-9]+)" channel; in
      if m == null then null else elemAt m 0;
    asBetaDate = let m = match "beta-([0-9]+-[0-9]+-[0-9]+)" channel; in
      if m == null then null else elemAt m 0;

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
    # "1.49.0"
    else if asVersion != null then
      assertWith (date == null) "Stable version with specific date is not supported"
        manifests.stable.${channel} or (throw "Stable ${channel} is not available")
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
              Available profiles are: ${self.lib.concatStringsSep ", " (builtins.attrNames toolchain._profiles)}
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
    inherit (builtins) readFile match fromTOML head;
    content = readFile path;
    legacy = match "([^\r\n]+)\r?\n?" content;
  in if legacy != null
    then fromRustupToolchain { channel = head legacy; }
    else fromRustupToolchain (fromTOML content).toolchain;

  getComponentsWithFixedPlatform = pkgs: pkgname: stdenv:
    let
      pkg = pkgs.${pkgname};
      srcInfo = pkg.target.${super.rust.toRustTarget stdenv.targetPlatform} or pkg.target."*";
      components = srcInfo.components or [];
      componentNamesList =
        builtins.map (pkg: pkg.pkg) (builtins.filter (pkg: (pkg.target != "*")) components);
    in
      componentNamesList;

  getExtensions = pkgs: pkgname: stdenv:
    let
      inherit (super.lib) unique;
      pkg = pkgs.${pkgname};
      rustTarget = super.rust.toRustTarget stdenv.targetPlatform;
      srcInfo = pkg.target.${rustTarget} or pkg.target."*" or (throw "${pkgname} is no available");
      extensions = srcInfo.extensions or [];
      extensionNamesList = unique (builtins.map (pkg: pkg.pkg) extensions);
    in
      extensionNamesList;

  hasTarget = pkgs: pkgname: target:
    pkgs ? ${pkgname}.target.${target};

  getTuples = pkgs: name: targets:
    builtins.map (target: { inherit name target; }) (builtins.filter (target: hasTarget pkgs name target) targets);

  # In the manifest, a package might have different components which are bundled with it, as opposed as the extensions which can be added.
  # By default, a package will include the components for the same architecture, and offers them as extensions for other architectures.
  #
  # This functions returns a list of { name, target } attribute sets, which includes the current system package, and all its components for the selected targets.
  # The list contains the package for the pkgTargets as well as the packages for components for all compTargets
  getTargetPkgTuples = pkgs: pkgname: pkgTargets: compTargets: stdenv:
    let
      inherit (builtins) elem;
      inherit (super.lib) intersectLists;
      components = getComponentsWithFixedPlatform pkgs pkgname stdenv;
      extensions = getExtensions pkgs pkgname stdenv;
      compExtIntersect = intersectLists components extensions;
      tuples = (getTuples pkgs pkgname pkgTargets) ++ (builtins.map (name: getTuples pkgs name compTargets) compExtIntersect);
    in
      tuples;

  getFetchUrl = pkgs: pkgname: target: stdenv: fetchurl:
    let
      srcInfo = pkgs.${pkgname}.target.${target};
    in
      mkComponentSrc {
        url = srcInfo.xz_url;
        sha256 = srcInfo.xz_hash;
        inherit fetchurl;
      };

  mkComponentSrc = { url, sha256, fetchurl }:
    let
      inherit (builtins) match elemAt;
      url' = builtins.replaceStrings [" "] ["%20"] url; # This is required or download will fail.
      # Filter names like `llvm-tools-1.34.2 (6c2484dc3 2019-05-13)-aarch64-unknown-linux-gnu.tar.xz`
      matchParenPart = match ".*/([^ /]*) [(][^)]*[)](.*)" url;
      name = if matchParenPart == null then "" else (elemAt matchParenPart 0) + (elemAt matchParenPart 1);
    in
      fetchurl { inherit name sha256; url = url'; };

  checkMissingExtensions = pkgs: pkgname: stdenv: extensions:
    let
      inherit (builtins) head;
      inherit (super.lib) concatStringsSep subtractLists;
      availableExtensions = getExtensions pkgs pkgname stdenv;
      missingExtensions = subtractLists availableExtensions extensions;
      extensionsToInstall =
        if missingExtensions == [] then extensions else throw ''
          While compiling ${pkgname}: the extension ${head missingExtensions} is not available.
          Select extensions from the following list:
          ${concatStringsSep "\n" availableExtensions}'';
    in
      extensionsToInstall;

  getComponents = pkgs: pkgname: targets: extensions: targetExtensions: stdenv: fetchurl:
    let
      inherit (builtins) head map;
      inherit (super.lib) flatten remove subtractLists unique;
      targetExtensionsToInstall = checkMissingExtensions pkgs pkgname stdenv targetExtensions;
      extensionsToInstall = checkMissingExtensions pkgs pkgname stdenv extensions;
      hostTargets = [ "*" (super.rust.toRustTarget stdenv.hostPlatform) (super.rust.toRustTarget stdenv.targetPlatform) ];
      pkgTuples = flatten (getTargetPkgTuples pkgs pkgname hostTargets targets stdenv);
      extensionTuples = flatten (map (name: getTargetPkgTuples pkgs name hostTargets targets stdenv) extensionsToInstall);
      targetExtensionTuples = flatten (map (name: getTargetPkgTuples pkgs name targets targets stdenv) targetExtensionsToInstall);
      pkgsTuples = pkgTuples ++ extensionTuples ++ targetExtensionTuples;
      missingTargets = subtractLists (map (tuple: tuple.target) pkgsTuples) (remove "*" targets);
      pkgsTuplesToInstall =
        if missingTargets == [] then pkgsTuples else throw ''
          While compiling ${pkgname}: the target ${head missingTargets} is not available for any package.'';
    in
      map (tuple: { name = tuple.name; src = (getFetchUrl pkgs tuple.name tuple.target stdenv fetchurl); }) pkgsTuplesToInstall;

  mkComponent = { pname, version, src }:
    self.stdenv.mkDerivation {
      inherit pname version src;

      # No point copying src to a build server, then copying back the
      # entire unpacked contents after just a little twiddling.
      preferLocalBuild = true;

      nativeBuildInputs = [ self.cpio ];

      installPhase = ''
        runHook preInstall
        installerVersion=$(< ./rust-installer-version)
        if [[ "$installerVersion" != 3 ]]; then
          echo "Unknown installer version: $installerVersion"
        fi
        while read -r comp; do
          echo "Installing component $comp"
          # Use cpio with file list instead of forking tons of cp.
          cut -d: -f2 <"$comp/manifest.in" | cpio --quiet -pdD "$comp" "$out"
        done <./components
        runHook postInstall
      '';

      # (@nbp) TODO: Check on Windows and Mac.
      # This code is inspired by patchelf/setup-hook.sh to iterate over all binaries.
      preFixup = ''
        setInterpreter() {
          local dir="$1"
          [ -e "$dir" ] || return 0
          header "Patching interpreter of ELF executables and libraries in $dir"
          local i
          while IFS= read -r -d ''$'\0' i; do
            if [[ "$i" =~ .build-id ]]; then continue; fi
            if ! isELF "$i"; then continue; fi
            echo "setting interpreter of $i"

            if [[ -x "$i" ]]; then
              # Handle executables
              patchelf \
                --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
                --set-rpath "${super.lib.makeLibraryPath [ self.zlib ]}:$out/lib" \
                "$i" || true
            else
              # Handle libraries
              patchelf \
                --set-rpath "${super.lib.makeLibraryPath [ self.zlib ]}:$out/lib" \
                "$i" || true
            fi
          done < <(find "$dir" -type f -print0)
        }
        setInterpreter $out
      '';

      postFixup = ''
        # Function moves well-known files from etc/
        handleEtc() {
          if [[ -d "$1" ]]; then
            mkdir -p "$(dirname "$2")"
            mv -T "$1" "$2"
          fi
        }
        if [[ -e "$out/etc" ]]; then
          handleEtc "$out/etc/bash_completion.d" "$out/share/bash-completion/completions"
          rmdir $out/etc || { echo "Installer tries to install to /etc: $(ls $out/etc)"; exit 1; }
        fi
      '';

      dontStrip = true;
    };

  aggregateComponents = { pname, version, components }:
    self.pkgs.symlinkJoin {
      name = pname + "-" + version;
      inherit pname version;

      paths = components;

      postBuild = ''
        # If rustc or rustdoc is in the derivation, we need to copy their
        # executable into the final derivation. This is required
        # for making them find the correct SYSROOT.
        for target in $out/bin/{rustc,rustdoc,miri}; do
          if [ -e $target ]; then
            cp --remove-destination "$(realpath -e $target)" $target
          fi
        done

        if [ -e $out/bin/cargo-miri ]; then
          cargo_miri=$(readlink $out/bin/cargo-miri)
          cp -f ${./cargo-miri-wrapper.sh} $out/bin/cargo-miri
          chmod +w $out/bin/cargo-miri
          substituteInPlace $out/bin/cargo-miri \
            --replace "@bash@" "${self.pkgs.bash}/bin/bash" \
            --replace "@miri@" "$cargo_miri" \
            --replace "@out@" "$out"
        fi

        # `symlinkJoin` (`runCommand`) doesn't handle propagated dependencies.
        # Need to do it manually.
        mkdir -p "$out/nix-support"
        echo "$propagatedBuildInputs" > "$out/nix-support/propagated-build-inputs"
        if [[ -n "$depsTargetTargetPropagated" ]]; then
          echo "$depsTargetTargetPropagated" > "$out/nix-support/propagated-target-target-deps"
        fi
      '';

      # FIXME: If these propagated dependencies go components, darwin build will fail with "`-liconv` not found".
      propagatedBuildInputs = [ self.stdenv.cc ];
      depsTargetTargetPropagated =
        self.lib.optional (self.stdenv.targetPlatform.isDarwin) self.targetPackages.libiconv;

      meta.platforms = self.lib.platforms.all;
    };

  # Resolve final components to install from mozilla-overlay style `extensions`, `targets` and `targetExtensions`.
  #
  # `componentSet` has a layout of `componentSet.<name>.<rust-target> : Derivation`.
  # `targetComponentsList` is a list of all component names for target platforms.
  # `name` is only used for error message.
  #
  # Returns a list of component derivations, or throw if failed.
  resolveComponents = { name, componentSet, targetComponentsList, extensions, targets, targetExtensions }:
    let
      inherit (self.lib) flatten elem isString filter any remove concatStringsSep concatMapStrings attrNames;
      rustHostPlatform = self.rust.toRustTarget self.stdenv.hostPlatform;

      collectComponentTargets = compName: comp:
        # Platform irrelevent components like `rust-src`.
        if comp ? "*" then
          comp."*"
        # Components for target platform like `rust-std`.
        else if elem compName targetComponentsList then
          collectTargetComponentTargets compName comp
        # Components for host platform like `rustc`.
        else
          comp.${rustHostPlatform} or "Host component `${compName}` doesn't support target `${rustHostPlatform}`";

      collectTargetComponentTargets = compName: comp:
        let selected = remove null (map (tgt: comp.${tgt} or null) targets); in
        if selected == []
          then throw "Extension `${compName}` doesn't support any of targets: ${concatStringsSep ", " targets}"
          else selected;

      collectComponents = name: collectComponentTargets name (componentSet.${name} or "Missing extension `${name}`");
      collectTargetComponents = name: collectTargetComponentTargets name (componentSet.${name} or "Missing target extension `${name}`");

      result =
        flatten (map collectComponents extensions) ++
        flatten (map collectTargetComponents targetExtensions);

      isTargetUnused = target:
        !any (name: componentSet ? ${name}.${target})
          (filter (name: elem name targetComponentsList) extensions ++ targetExtensions);

      errors = filter isString result ++
        map (tgt: "Target `${tgt}` is not supported by any components or extensions")
          (filter isTargetUnused targets);

    in
      if errors == [] then result
      else throw ''
        Component resolution failed for ${name}
        - note: available extensions are ${concatStringsSep ", " (attrNames componentSet)}
        ${concatMapStrings (msg: "- ${msg}\n") errors}
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
    inherit (builtins) elemAt;
    inherit (super) makeOverridable;
    inherit (super.lib) flip mapAttrs;
    inherit (super.rust) toRustTarget;

    maybeRename = name: manifest.renames.${name}.to or name;

    # For legacy pre-aggregated package `rust`.
    mkPackage = name: pkg:
      makeOverridable ({ extensions, targets, targetExtensions, stdenv, fetchurl, patchelf }:
        let
          extensions' = map maybeRename extensions;
          targetExtensions' = map maybeRename targetExtensions;
          namesAndSrcs = getComponents manifest.pkg name targets extensions' targetExtensions' stdenv fetchurl;
        in
          aggregateComponents {
            pname = name;
            version = manifest.version;
            components = map ({ name, src }: (mkComponent {
              pname = name;
              inherit (manifest) version;
              inherit src;
            })) namesAndSrcs;
          }
      ) {
        extensions = [];
        targets = [];
        targetExtensions = [];
        inherit (self) stdenv fetchurl patchelf;
      };

    # componentSet.cargo.x86_64-unknown-linux-gnu = <derivation>;
    componentSet = mapAttrs (name: pkg:
      mapAttrs (target: { xz_hash, xz_url }:
        mkComponent {
          pname = name;
          inherit (manifest) version;
          src = mkComponentSrc {
            url = xz_url;
            sha256 = xz_hash;
            fetchurl = self.fetchurl;
          };
        }
      ) pkg.target
    ) (removeAttrs manifest.pkg ["rust"]) //
    mapAttrs (name: { to }: componentSet.${to}) manifest.renames;

    mkProfile = name: componentNames:
      makeOverridable ({ extensions, targets, targetExtensions }:
        aggregateComponents {
          pname = "rust-${name}";
          version = manifest.version;
          components = resolveComponents {
            name = "rust-${name}-${manifest.version}";
            inherit componentSet;
            inherit (manifest) targetComponentsList;
            extensions = componentNames ++ extensions;
            targets = [
              (toRustTarget self.stdenv.hostPlatform) # Build script requires host std.
              (toRustTarget self.stdenv.targetPlatform)
            ] ++ targets;
            inherit targetExtensions;
          };
        }
      ) {
        extensions = [];
        targets = [];
        targetExtensions = [];
      };

    profiles = mapAttrs mkProfile manifest.profiles;

  in
    # Components.
    mapAttrs (name: targets: targets."*" or targets.${toRustTarget self.stdenv.hostPlatform} or null) componentSet //
    # Profiles.
    profiles //
    {
      # Legacy support for special pre-aggregated package.
      # It has more components than `default` profile but less than `complete` profile.
      rust =
        let pkg = mkPackage "rust" manifest.pkg.rust; in
        if builtins.match ".*[.].*[.].*" != null && profiles != {}
          then builtins.trace ''
            Rust ${manifest.version}:
            Pre-aggregated package `rust` is not encouraged for stable channel since it contains almost all and uncertain components.
            Consider use `default` profile like `rust-bin.stable.latest.default` and override it with extensions you need.
            See README for more information.
          '' pkg
          else pkg;

      # Internal use.
      _components = componentSet;
      _profiles = profiles;
      _version = manifest.version;
    };

  # Same as `toolchainFromManifest` but read from a manifest file.
  toolchainFromManifestFile = path: toolchainFromManifest (builtins.fromTOML (builtins.readFile path));

  # Override all pkgs of a toolchain set.
  overrideToolchain = attrs: super.lib.mapAttrs (name: pkg: pkg.override attrs);

  # From a git revision of rustc.
  # This does the same thing as crate `rustup-toolchain-install-master`.
  # But you need to manually provide component hashes.
  fromRustcRev = {
    # Package name of the derivation.
    pname ? "rust-custom",
    # Git revision of rustc.
    rev,
    # Attrset with component name as key and its SRI hash as value.
    components,
    # Rust target to download.
    target ? super.rust.toRustTarget self.stdenv.targetPlatform
  }: let
    shortRev = builtins.substring 0 7 rev;
    components' = super.lib.mapAttrsToList (compName: hash: mkComponent {
      pname = compName;
      version = shortRev;
      src = self.fetchurl {
        url = if compName == "rust-src"
          then "https://ci-artifacts.rust-lang.org/rustc-builds/${rev}/${compName}-nightly.tar.xz"
          else "https://ci-artifacts.rust-lang.org/rustc-builds/${rev}/${compName}-nightly-${target}.tar.xz";
        inherit hash;
      };
    }) components;
  in
    aggregateComponents {
      inherit pname;
      version = shortRev;
      components = components';
    };

in {
  # For each channel:
  #   rust-bin.stable.latest.cargo
  #   rust-bin.stable.latest.rust   # Aggregate all others. (recommended)
  #   rust-bin.stable.latest.rustc
  #   rust-bin.stable.latest.rust-analysis
  #   rust-bin.stable.latest.rust-docs
  #   rust-bin.stable.latest.rust-src
  #   rust-bin.stable.latest.rust-std
  #
  # For a specific version of stable:
  #   rust-bin.stable."1.47.0".rust
  #
  # For a specific date of beta:
  #   rust-bin.beta."2021-01-01".rust
  #
  # For a specific date of nightly:
  #   rust-bin.nightly."2020-01-01".rust
  rust-bin = with builtins;
    (super.rust-bin or {}) //
    mapAttrs (channel: mapAttrs (version: toolchainFromManifest)) super.rust-bin.manifests //
    {
      inherit fromRustupToolchain fromRustupToolchainFile;
      # Experimental feature.
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
      fromManifestFile = manifestFilePath: { stdenv, fetchurl, patchelf }@deps: builtins.trace ''
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
