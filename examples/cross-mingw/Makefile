# This Makefile is expected to be run inside nix-shell.

CARGO_FLAGS := --target x86_64-pc-windows-gnu

.PHONY: all
all: Cargo.toml Cargo.lock src/main.rs
	cargo build $(CARGO_FLAGS)

.PHONY: test
run: all
	cargo run $(CARGO_FLAGS)
