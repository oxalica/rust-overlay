# See docs/cross_compilation.md for details.
(import <nixpkgs> {
  crossSystem = {
    config = "wasm32-wasi";
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
      # CARGO_TARGET_WASM32_WASI_LINKER = "${stdenv.cc.targetPrefix}cc";
      CARGO_TARGET_WASM32_WASI_RUNNER = "wasmtime";
    }
  )
  { }
