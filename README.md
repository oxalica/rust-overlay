# rust-overlay

![CI](https://github.com/oxalica/rust-overlay/workflows/CI/badge.svg)
![sync-channels](https://github.com/oxalica/rust-overlay/workflows/sync-channels/badge.svg)

*Pure and reproducible* overlay for binary distributed rust toolchains.
A compatible but better replacement for rust overlay of [mozilla/nixpkgs-mozilla][mozilla].

Hashes of toolchain components are pre-fetched (and compressed) in tree (`manifests` directory),
so the evaluation is *pure* and no need to have network (but [nixpkgs-mozilla][mozilla] does).
It also works well with [Nix Flakes](https://nixos.wiki/wiki/Flakes).

- The toolchain hashes are auto-updated daily using GitHub Actions.
- Current oldest supported version is stable 1.29.0 and beta/nightly 2018-09-13
  (which are randomly chosen).

## Use as a classic Nix overlay

You can put the code below into your `~/.config/nixpkgs/overlays.nix`.
```nix
[ (import (builtins.fetchTarball "https://github.com/oxalica/rust-overlay/archive/master.tar.gz")) ]
```
Then the provided attribute paths are available in nix command.
```bash
$ nix-env -iA rust-bin.stable.latest.default # Do anything you like.
```

Alternatively, you can install it into nix channels.
```bash
$ nix-channel --add https://github.com/oxalica/rust-overlay/archive/master.tar.gz rust-overlay
$ nix-channel --update
```
And then feel free to use it anywhere like
`import <nixpkgs> { overlays = [ (import <rust-overlay>) ]; }` in your nix shell environment.

## Use with Nix Flakes

This repository already has flake support.

NOTE: **Only the output `overlay` is stable and preferred to be used in your flake.**
Other outputs like `packages` and `defaultPackage` are for human try and are subject to change.

For a quick play, just use `nix shell` to bring the latest stable rust toolchain into scope.
(All commands below requires preview version of Nix with flake support.)
```shell
$ nix shell github:oxalica/rust-overlay
$ rustc --version
rustc 1.49.0 (e1884a8e3 2020-12-29)
$ cargo --version
cargo 1.49.0 (d00d64df9 2020-12-05)
```

### Example: NixOS Configuration

Here's an example of using it in nixos configuration.
```nix
{
  description = "My configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { nixpkgs, rust-overlay, ... }: {
    nixosConfigurations = {
      hostname = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix # Your system configuration.
          ({ pkgs, ... }: {
            nixpkgs.overlays = [ rust-overlay.overlay ];
            environment.systemPackages = [ pkgs.rust-bin.stable.latest.default ];
          })
        ];
      };
    };
  };
}
```

### Example: Using `devShell` and `nix develop`

Running `nix develop` will create a shell with the default nightly Rust toolchain installed:

```nix
{
  description = "A devShell example";

  inputs = {
    nixpkgs.url      = "github:nixos/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url  = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let 
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
      in
      {
        devShell = pkgs.mkShell {
        	buildInputs = [
          	pkgs.openssl
            pkgs.pkgconfig
            pkgs.exa
            pkgs.fd
            pkgs.rust-bin.nightly.latest.default
          ];

          shellHook = ''
            alias ls=exa
            alias find=fd
          '';
        };
      }
    );
}
```

## Attributes provided by the overlay

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

    # [Experimental]
    # Custom toolchain from a specific rustc git revision.
    # This does almost the same thing as `rustup-toolchain-install-master`. (https://crates.io/crates/rustup-toolchain-install-master)
    # Parameter `components` should be an attrset with component name as key and its SRI hash as value.
    fromRustcRev = { pname ? .., rev, components, target ? .. }: «derivation»;

    stable = {
      # The latest stable toolchain.
      latest = {
        # [Experimental]
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

Some examples (assume `nixpkgs` had the overlay applied):

- Latest stable/beta/nightly rust with almost all components (provided the same as `mozilla-overlay`):
  `nixpkgs.rust-bin.{stable,beta,nightly}.latest.rust`
- *\[Experimental\]*
  Latest stable/beta/nightly rust with `default` or `minimal` profile (provided the same as default behavior of `rustup install`).
  `nixpkgs.rust-bin.{stable,beta,nightly}.latest.{default,minimal}`

  Note: `default` profile on `nightly` may not always be available due to absense of required components.
  You can check availability on [Rustup packages availibility](https://rust-lang.github.io/rustup-components-history/).

- A specific version of stable rust:
  `nixpkgs.rust-bin.stable."1.48.0".default`
- A specific date of beta rust:
  `nixpkgs.rust-bin.beta."2021-01-01".default`
- A specific date of nightly rust:
  `nixpkgs.rust-bin.nightly."2020-12-31".default`
- Latest stable rust with additional component `rust-src` and extra target
  `arm-unknown-linux-gnueabihf`:

  ```nix
  nixpkgs.rust-bin.stable.latest.default.override {
    extensions = [ "rust-src" ];
    targets = [ "arm-unknown-linux-gnueabihf" ];
  }
  ```

- If you already have a [`rust-toolchain` file for rustup][rust-toolchain],
  you can simply use `fromRustupToolchainFile` to get the customized toolchain derivation.

  ```nix
  nixpkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain
  ```

- *\[Experimental\]*
  Toolchain with specific rustc git revision.
  This is useful for development of rust components like [MIRI](https://github.com/rust-lang/miri).
  Note: the example below may not built since upstream CI periodly removes old artifacts.
  ```nix
  rust-bin.fromRustcRev {
    rev = "a2cd91ceb0f156cb442d75e12dc77c3d064cdde4";
    components = {
      rustc = "sha256-x+OkPVStX00AiC3GupIdGzWluIK1BnI4ZCBbg72+ZuI=";
      rust-src = "sha256-13PpzzYtd769Xkb0QzHpNfYCOnLMWFolc9QyYq98z2k=";
    };
  }
  ```

- See more examples in directory `examples`.

For more details, see also the source code of `./rust-overlay.nix`.

[mozilla]: https://github.com/mozilla/nixpkgs-mozilla
[rust-toolchain]: https://rust-lang.github.io/rustup/overrides.html#the-toolchain-file
