# `rust-overlay` reference

All public attributes provided by the overlay are below. Fields not defined here are for internal usage.

```nix
{
  rust-bin = {
    # The default dist url for fetching.
    # Override it if you want to use a mirror server.
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
  };

  # These are for compatibility with nixpkgs-mozilla and
  # provide same toolchains as `rust-bin.*`.
  latest.rustChannels = /* ... */;
  rustChannelOf = /* ... */;
  rustChannelOfTargets = /* ... */;
  rustChannels = /* ... */;
}
```

For more details, see also the source code of [`rust-overlay.nix`](../rust-overlay.nix).
