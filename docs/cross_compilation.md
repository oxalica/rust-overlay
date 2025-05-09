# Cross compilation with `rust-overlay`

## `shell.nix` and `nix shell` development environment

There are examples for cross compilation in [`example` directory](../examples).
To try examples,
1. `cd` into `example/cross-aarch64` (or other directory).
2. `nix-shell` to enter the development environment.
3. `make run` to build and run the program in an emulator.

The structure of `shell.nix` should like this,
```nix
# Import from global `<nixpkgs>`. Can also be from flake input if you like.
(import <nixpkgs> {
  # Target triple in nixpkgs format, can be abbreviated.
  # Some special targets, like `wasm32-wasi`, need special configurations here, check
  # `examples/cross-wasi/shell.nix` for details.
  crossSystem = "aarch64-linux";
  # Apply `rust-overlay`.
  overlays = [ (import ../..) ];

# Workaround: we need `callPackage` to enable auto package-splicing, thus we don't need to manually prefix
# everything in `nativeBuildInputs` with `buildPackages.`.
# See: https://github.com/NixOS/nixpkgs/issues/49526
}).callPackage (
{ mkShell, stdenv, rust-bin, pkg-config, openssl, qemu }:
mkShell {
  # Build-time dependencies. build = host = your-machine, target = aarch64
  # Typically contains,
  # - Configure-related: cmake, pkg-config
  # - Compiler-related: gcc, rustc, binutils
  # - Code generators run at build time: yacc, bision
  nativeBuildInputs = [
    # `minimal` is enough for basic building and running.
    # Can also be `default` to bring other components like `rustfmt`, `clippy`, and etc.
    rust-bin.stable.latest.minimal
    pkg-config
  ];

  # Build-time tools which are target agnostic. build = host = target = your-machine.
  # Emulaters should essentially also go `nativeBuildInputs`. But with some packaging issue,
  # currently it would cause some rebuild.
  # We put them here just for a workaround.
  # See: https://github.com/NixOS/nixpkgs/pull/146583
  depsBuildBuild = [ qemu ];

  # Run-time dependencies. build = your-machine, host = target = aarch64
  # Usually are libraries to be linked.
  buildInputs = [ openssl ];

  # Tell cargo about the linker and an optional emulater. So they can be used in `cargo build`
  # and `cargo run`.
  # Environment variables are in format `CARGO_TARGET_<UPPERCASE_UNDERSCORE_RUST_TRIPLE>_LINKER`.
  # They can also be set in `.cargo/config.toml` instead.
  # See: https://doc.rust-lang.org/cargo/reference/config.html#target
  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER = "${stdenv.cc.targetPrefix}cc";
  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUNNER = "qemu-aarch64";
}) {}
```

For more details about these different kinds of dependencies,
see also [Nix Wiki - Cross Compiling][wiki-cross]

## Flakes and `nix develop` development environment

Unfortunately flake output layout does not natively support cross-compilation
(see [NixOS/nix#5157][flake-cross-issue]). We provide `mkRustBin` to allow
construction of `rust-bin` on an existing nixpkgs to leverage flake benefits of
not-importing nixpkgs again, with the cost of re-instantiating `rust-bin` for
each host-target tuples.

Pass the spliced packages for your cross-compilation target to `mkRustBin` to
get corresponding compiler toolchains for them.

```nix
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform;
  rust-bin = rust-overlay.lib.mkRustBin { } pkgs.buildPackages;
in
# Need `callPackage` here, see https://github.com/NixOS/nixpkgs/issues/49526
pkgs.callPackage (
  { mkShell }:
  mkShell {
    nativeBuildInputs = [ rust-bin.stable.latest.minimal ];
  }
) { }
```

The full example can be seen in
[`examples/cross-aarch64/flake.nix`](../examples/cross-aarch64/flake.nix).
To try it,
1. `cd` into `example/cross-aarch64`.
2. `nix develop` to enter the development environment.
3. `make run` to build and run the program in an emulator.

[wiki-cross]: https://wiki.nixos.org/wiki/Cross_Compiling#How_to_specify_dependencies
[flake-cross-issue]: https://github.com/NixOS/nix/issues/5157
