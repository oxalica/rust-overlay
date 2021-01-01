# rust-overlay

*Pure and reproducible* overlay for binary distributed rust toolchains.
A better replacement for github:mozilla/nixpkgs-mozilla

Hashes of toolchain components are pre-fetched (and compressed) in `manifests` directory.
So there's no need to have network access during nix evaluation (but nixpkgs-mozilla does).

Since the evaluation is now *pure*, it also means this can work well with [Nix Flakes](https://nixos.wiki/wiki/Flakes).

- [ ] Auto-updating is TODO.
- Current oldest supported version is stable 1.29.0 and nightly 2018-09-13
  (which is randomly chosen).

## Use as classical nix overlay

The installaction and usage are exactly the same as nixpkgs-mozilla.
You can follow https://github.com/mozilla/nixpkgs-mozilla#rust-overlay and just replace the url to
https://github.com/oxalica/rust-overlay

You can put the code below into your `~/.config/nixpkgs/overlays.nix`.
```nix
[ (import (builtins.fetchTarball https://github.com/oxalica/rust-overlay/archive/master.tar.gz)) ]
```

Or install it into `nix-channel`:
```shell
$ nix-channel --add https://github.com/oxalica/rust-overlay/archive/master.tar.gz rust-overlay
```
And then feel free to use it anywhere like
`import <nixpkgs> { overlays = [ (import <rust-overlay>) ] }` in your nix shell environment

## Use with Nix Flakes

This repository already has flake support. So you can simply use it as input.
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
            environment.systemPackages = [ pkgs.latest.rustChannels.stable.rust ];
          })
        ];
      };
    };
  };
}
```

## Interface

The overlay re-use many codes from nixpkgs/mozilla and the interface is **almost the same**.
It provides `latest.rustChannels.{stable,nightly}.<toolchain-component>` and `rustChannelOf`.

To use the latest stable or nightly rust toolchain, the easiest way is just to install
`latest.rustChannels.{stable,nightly}.rust`, which combines `rustc`, `cargo`, `rustfmt` and
all other default components.

You can also pin to specific nightly toolchain using `rustChannelOf`:
```nix
(nixpkgs.rustChannelOf { date = "2020-01-01"; channel = "nightly"; }).rust
```

Customize an toolchain.
```nix
nixpkgs.latest.rustChannels.stable.rust.override {
  extensions = [
    "rust-src"
  ];
  targets = [
    "x86_64-unknown-linux-musl"
    "arm-unknown-linux-gnueabihf"
  ];
}
```

For more details, see `./rust-overlay.nix` or README of https://github.com/mozilla/nixpkgs-mozilla.
