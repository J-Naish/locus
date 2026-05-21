#!/bin/sh
set -eu

case "${CONFIGURATION:-Debug}" in
  Release)
    cargo_flags="--release"
    ;;
  *)
    cargo_flags=""
    ;;
esac

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Xcode's script environment can miss Homebrew/rustup paths, especially when
# launched from the GUI rather than an interactive shell.
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

cargo build --manifest-path "$repo_root/core/Cargo.toml" -p app-ffi $cargo_flags
