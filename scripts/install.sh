#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${PREFIX:-"$HOME/.local"}
bindir="$prefix/bin"

mkdir -p "$bindir"
install -m 0755 "$script_dir/tailport" "$bindir/tailport"
ln -sfn tailport "$bindir/tp"

printf 'Installed tailport and tp in %s\n' "$bindir"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) printf 'Add %s to PATH before running tp.\n' "$bindir" ;;
esac
