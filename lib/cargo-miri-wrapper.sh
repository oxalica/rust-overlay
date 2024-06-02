#!@bash@ -e
src_dir="@out@/lib/rustlib/src/rust/library"
if [[ ! -v XARGO_RUST_SRC ]]; then
    if [[ ! -d "$src_dir" ]]; then
        echo '`rust-src` is required by miri but not installed.' >&2
        echo 'Please either install component `rust-src` or set `XARGO_RUST_SRC`.' >&2
        exit 1
    fi
    export XARGO_RUST_SRC="$src_dir"
fi
exec -a "$0" "@cargo_miri@" "$@"
