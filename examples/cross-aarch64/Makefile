.PHONY: all test

test: all
	nix-shell ./shell.nix --command \
		"cargo test --target aarch64-unknown-linux-gnu"

all: Cargo.toml Cargo.lock src/main.rs
	nix-shell ./shell.nix --command \
		"cargo test --target aarch64-unknown-linux-gnu --no-run"
