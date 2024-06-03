# Reference

We provides two entry interfaces:

1.  Overlay interface, via `default.nix` (non-flake) or
    `rust-overlay.overlays.default` (flake).

    This provides a [nixpkgs overlay][nixpkgs-overlay] to be used when
    importing nixpkgs. The overlay will (try its best) not modify any existing
    attributes of nixpkgs, but adds these new attributes:

    - `rust-bin`,
      where all main functionalities resides.
      Its structure is documented in the next section.

    - `latest`, `rustChannelOf`, `rustChannelOfTargets`, `rustChannels`,
      for compatibility with [nixpkgs-mozilla].

      They are built on top of `rust-bin` with only structure/argument
      differences, and will provide the same corresponding derivations as
      `rust-bin`.

[nixpkgs-overlay]: https://wiki.nixos.org/wiki/Overlays
[nixpkgs-mozilla]: https://github.com/mozilla/nixpkgs-mozilla

2.  Builder interface, via `rust-overlay.lib.mkRustBin` (flake only).

    It is a function with type
    `{ distRoot ? ... } -> (pkgs: attrset) -> attrset`.

    It returns an attrset with the same structure as `rust-bin` attribute
    mentioned above, with the argument of an already imported (instantiated)
    nixpkgs.

    Notably, only the attrset `rust-bin` is returned, so this builder will not
    give you any nixpkgs-mozilla compatible attributes.

## `rust-bin` structure

```nix
{
  # The default dist url for fetching.
  #
  # For the overlay interface, this attribute is overridable. Changing it will
  # also change all dependent URLs for source derivations (FOD). Useful for
  # setting mirrors.
  distRoot = "https://static.rust-lang.org/dist";

  # Select a toolchain and aggregate components by rustup's `rust-toolchain` file format.
  # See: https://rust-lang.github.io/rustup/overrides.html#the-toolchain-file
  fromRustupToolchain = { channel, components ? [], targets ? [] }: «derivation»;
  # Same as `fromRustupToolchain` but read from a `rust-toolchain` file (legacy one-line string or in TOML).
  fromRustupToolchainFile = rust-toolchain-file-path: «derivation»;

  # Select the latest nightly toolchain which have specific components or profile available.
  # This helps nightly users in case of latest nightly may not contains all components they want.
  #
  # `selectLatestNightlyWith (toolchain: toolchain.default)` selects the latest nightly toolchain
  # with all `default` components (rustc, cargo, rustfmt, ...) available.
  selectLatestNightlyWith = selector: «derivation»;

  # Custom toolchain from a specific rustc git revision.
  # This does almost the same thing as `rustup-toolchain-install-master`. (https://crates.io/crates/rustup-toolchain-install-master)
  # Parameter `components` should be an attrset with component name as key and its SRI hash as value.
  fromRustcRev = { pname ? …, rev, components, target ? … }: «derivation»;

  stable = {
    # The latest stable toolchain.
    latest = {
      # Profiles, predefined component sets.
      # See: https://rust-lang.github.io/rustup/concepts/profiles.html
      minimal = «derivation»;  # Only `cargo`, `rustc` and `rust-std`.
      default = «derivation»;  # The default profile of `rustup`. Good for general use.
      complete = «derivation»; # Do not use it. It almost always fails.

      # Pre-aggregated package provided by upstream, the most commonly used package in `mozilla-overlay`.
      # It consists of an uncertain number of components, usually more than the `default` profile of `rustup`
      # but less than `complete` profile.
      rust = «derivation»;

      # Individial components.
      rustc = «derivation»;
      cargo = «derivation»;
      rust-std = «derivation»;
      # ... other components
    };
    "1.49.0" = { /* toolchain */ };
    "1.48.0" = { /* toolchain */ };
    # ... other versions.
  };

  beta = {
    # The latest beta toolchain.
    latest = { /* toolchain */ };
    "2021-01-01" = { /* toolchain */ };
    "2020-12-30" = { /* toolchain */ };
    # ... other versions.
  };

  nightly = {
    # The latest nightly toolchain.
    # It is preferred to use `selectLatestNightlyWith` instead of this since
    # nightly toolchain may have components (like `rustfmt` or `rls`) missing,
    # making `default` profile unusable.
    latest = { /* toolchain */ };
    "2020-12-31" = { /* toolchain */ };
    "2020-12-30" = { /* toolchain */ };
    # ... other versions.
  };

  # ... Some internal attributes omitted.
}
```

## Flake output structure

```nix
{
  lib.mkRustBin = { distRoot ? /*...*/ }: pkgs: «attrset rust-bin»;
  overlays = {
    # The overlay.
    default = final: prev: «attrset»;
    # Alias to `default`.
    rust-overlay = final: prev: «attrset»;
  };

  # WARNING: The structure of `packages` here is to-be-determined and may be
  # renamed or modified in the future.
  packages.${system} = {
    # Stable toolchain of release major.minor.patch
    # The derivation is the "default" profile, and the "minimal" profile can be
    # accessed via `minimal` attribute.
    # This type is abbreviated as `«toolchain»` below.
    "rust_${major}_${minor}_${patch}" = «derivation» // { minimal = «derivation»; };
    # Alias to `rust_${latest-major-minor-patch}`.
    rust = «toolchain»; 
    # Alias to `rust`.
    default = «toolchain»; 

    # Nightly toolchain of a specific date.
    "rust-nightly_${yyyy}-${mm}-${dd}" = «toolchain»;
    # Alias to `rust-nightly_${latest-nightly-yyyy-mm-dd}`.
    rust-nightly = «toolchain»; 

    # Beta toolchain of a specific date.
    "rust-beta_${yyyy}-${mm}-${dd}" = «toolchain»;
    # Alias to `rust-beta_${latest-beta-yyyy-mm-dd}`.
    rust-beta = «toolchain»; 
  };

  # ... Some internal attributes omitted.
}
```

For more details, see also the source code of [`lib/rust-bin.nix`](../lib/rust-bin.nix).
