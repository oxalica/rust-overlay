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

  in
    if channel == "stable" then
      assertWith (date == null) "Stable version with specific date is not supported"
        manifests.stable.latest
    else if channel == "nightly" then
      manifests.nightly.${if date != null then date else "latest"} or (throw "Nightly ${date} is not available")
    else if channel == "beta" then
      throw "Beta channel is not supported yet"
    else if asVersion != null then
      assertWith (date == null) "Stable version with specific date is not supported"
        manifests.stable.${channel} or (throw "Stable ${channel} is not available")
    else if asNightlyDate != null then
      assertWith (date == null) "Cannot specify date in both `channel` and `date`"
        manifests.nightly.${asNightlyDate} or (throw "Nightly ${asNightlyDate} is not available")
    else throw "Unknown channel: ${channel}";

  # Select a toolchain and aggregate components by rustup's `rust-toolchain` file format.
  # See: https://github.com/ebroto/rustup/blob/c2db7dac6b38c99538eec472db9d23d18f918409/README.md#the-toolchain-file
  fromRustupToolchain = { channel, components ? [], targets ? [] }:
    (toolchainFromManifest (selectManifest { inherit channel; })).rust.override {
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
      inherit (builtins) match elemAt;
      pkg = pkgs.${pkgname};
      srcInfo = pkg.target.${target};
      url = builtins.replaceStrings [" "] ["%20"] srcInfo.xz_url; # This is required or download will fail.
      # Filter names like `llvm-tools-1.34.2 (6c2484dc3 2019-05-13)-aarch64-unknown-linux-gnu.tar.xz`
      matchParenPart = match ".*/([^ /]*) [(][^)]*[)](.*)" srcInfo.xz_url;
      name = if matchParenPart == null then "" else (elemAt matchParenPart 0) + (elemAt matchParenPart 1);
    in
      (super.fetchurl { inherit name url; sha256 = srcInfo.xz_hash; });

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

  installComponents = stdenv: namesAndSrcs:
    let
      inherit (builtins) map;
      installComponent = name: src:
        stdenv.mkDerivation {
          inherit name;
          inherit src;

          # No point copying src to a build server, then copying back the
          # entire unpacked contents after just a little twiddling.
          preferLocalBuild = true;

          nativeBuildInputs = [ self.python3 ];

          # VERBOSE_INSTALL = 1; # No spam by default.

          installPhase = ''
            runHook preInstall
            python3 ${./rust-installer.py}
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
              local oldIFS="$IFS"
              # Directories we are aware of, given as substitution lists
              for paths in \
                "etc/bash_completion.d","share/bash_completion/completions","etc/bash_completions.d","share/bash_completions/completions";
                do
                # Some directoties may be missing in some versions. If so we just skip them.
                # See https://github.com/mozilla/nixpkgs-mozilla/issues/48 for more infomation.
                if [ ! -e $paths ]; then continue; fi
                IFS=","
                set -- $paths
                IFS="$oldIFS"
                local orig_path="$1"
                local wanted_path="$2"
                # Rename the files
                if [ -d ./"$orig_path" ]; then
                  mkdir -p "$(dirname ./"$wanted_path")"
                fi
                mv -v ./"$orig_path" ./"$wanted_path"
                # Fail explicitly if etc is not empty so we can add it to the list and/or report it upstream
                rmdir ./etc || {
                  echo Installer tries to install to /etc:
                  find ./etc
                  exit 1
                }
              done
            }
            if [ -d "$out"/etc ]; then
              pushd "$out"
              handleEtc
              popd
            fi
          '';

          dontStrip = true;
        };
    in
      map (nameAndSrc: (installComponent nameAndSrc.name nameAndSrc.src)) namesAndSrcs;

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
  toolchainFromManifest = pkgs: let
    inherit (builtins) elemAt;
    inherit (super) makeOverridable;
    inherit (super.lib) flip mapAttrs;

    maybeRename = name: pkgs.renames.${name}.to or name;

    mkPackage = name: pkg:
      makeOverridable ({ extensions, targets, targetExtensions, stdenv, fetchurl, patchelf }:
        let
          m = builtins.match "([^ ]*) [(]([^ ]*) ([^ ]*)[)]" pkg.version;
          version =
            if m == null then pkg.version
            else if builtins.match ".*nightly.*" pkg.version != null then "nightly-${elemAt m 2}"
            else elemAt m 0;
          extensions' = map maybeRename extensions;
          targetExtensions' = map maybeRename targetExtensions;
          namesAndSrcs = getComponents pkgs.pkg name targets extensions' targetExtensions' stdenv fetchurl;
          components = installComponents stdenv namesAndSrcs;
          componentsOuts = builtins.map (comp: (super.lib.strings.escapeNixString (super.lib.getOutput "out" comp))) components;
        in
          super.pkgs.symlinkJoin {
            name = name + "-" + version;
            pname = name;
            inherit version;

            paths = components;
            postBuild = ''
              # If rustc or rustdoc is in the derivation, we need to copy their
              # executable into the final derivation. This is required
              # for making them find the correct SYSROOT.
              for target in $out/bin/{rustc,rustdoc}; do
                if [ -e $target ]; then
                  cp --remove-destination "$(realpath -e $target)" $target
                fi
              done
            '';

            # Add the compiler as part of the propagated build inputs in order
            # to run:
            #
            #    $ nix-shell -p rustChannels.stable.rust
            #
            # And get a fully working Rust compiler, with the stdenv linker.
            propagatedBuildInputs = [ stdenv.cc ];

            meta.platforms = stdenv.lib.platforms.all;
          }
      ) {
        extensions = [];
        targets = [];
        targetExtensions = [];
        inherit (self) stdenv fetchurl patchelf;
      };

    toolchain =
      mapAttrs mkPackage pkgs.pkg //
      mapAttrs (from: { to }: toolchain.${to}) pkgs.renames;

  in toolchain;

  # Same as `toolchainFromManifest` but read from a manifest file.
  toolchainFromManifestFile = path: toolchainFromManifest (builtins.fromTOML (builtins.readFile path));

  # Override all pkgs of a toolchain set.
  overrideToolchain = attrs: super.lib.mapAttrs (name: pkg: pkg.override attrs);

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
  # For a specific date of nightly:
  #   rust-bin.nightly."2020-01-01".rust
  rust-bin = with builtins;
    (super.rust-bin or {}) //
    mapAttrs (channel: mapAttrs (version: toolchainFromManifest)) super.rust-bin.manifests //
    {
      inherit fromRustupToolchain fromRustupToolchainFile;
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
      beta = throw "Beta channel is not supported yet";
      nightly = self.rust-bin.nightly.latest;
    };
  };

  rustChannelOfTargets = channel: date: targets:
    (self.rustChannelOf { inherit channel date; })
      .rust.override { inherit targets; };

  rustChannels = self.latest.rustChannels;
}
