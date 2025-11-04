# See docs/cross_compilation.md for details.
(import <nixpkgs> {
  crossSystem = {
    config = "wasm32-wasi";

    # NB. Rust use a different naming convention for target platforms and
    # differentiates multiple version of WASI specification by using "wasip?".
    # If this line is omitted, `wasm32-wasip1` (WASI 0.1) is assumed.
    # See: <https://blog.rust-lang.org/2024/04/09/updates-to-rusts-wasi-targets.html>
    #
    # If you changed this, also update `CARGO_TARGET_*_RUNNER` below.
    rust.rustcTarget = "wasm32-wasip1";

    # Nixpkgs currently only supports LLVM lld linker for wasm32-wasi.
    useLLVM = true;
  };
  overlays = [ (import ../..) ];
}).callPackage
  (
    # We don't need WASI C compiler from nixpkgs, so use `mkShellNoCC`.
    {
      mkShellNoCC,
      stdenv,
      rust-bin,
      wasmtime,
    }:
    mkShellNoCC {
      nativeBuildInputs = [ rust-bin.stable.latest.minimal ];

      depsBuildBuild = [ wasmtime ];

      # This is optional for wasm32-like targets, since rustc will automatically use
      # the bundled `lld` for linking.
      # CARGO_TARGET_WASM32_WASIP1_LINKER =

      CARGO_TARGET_WASM32_WASIP1_RUNNER = "wasmtime run";
    }
  )
  { }
