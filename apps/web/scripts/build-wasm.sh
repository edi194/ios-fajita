#!/bin/sh
# Builds the Renegade root builder (tools/renegade-wasm, Rust) for the browser into src/patcher/renegade.wasm.
# Needs rustup with the wasm32-unknown-unknown target (rustup target add wasm32-unknown-unknown).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
crate="$here/../../../tools/renegade-wasm"
out="$here/../src/patcher/renegade.wasm"
cargo build --release --target wasm32-unknown-unknown --manifest-path "$crate/Cargo.toml"
mkdir -p "$(dirname "$out")"
cp "$crate/target/wasm32-unknown-unknown/release/renegade_wasm.wasm" "$out"
echo "wrote $out ($(wc -c < "$out" | tr -d ' ') bytes)"
