#!/bin/zsh

set -eu
setopt pipefail

repo_root="${0:A:h:h}"
version=$(< "$repo_root/VERSION")
dist_dir="$repo_root/dist"
darwin_name="tailport-$version-darwin"
darwin_archive_name="$darwin_name.tar.gz"
windows_name="tailport-$version-windows"
windows_script_name="$windows_name.ps1"
windows_archive_name="$windows_name.zip"
source_name="tailport-$version-source"
source_archive_name="$source_name.tar.gz"

command -v zip >/dev/null 2>&1 || {
  print -u2 -- 'package: zip is required to create the Windows release archive'
  exit 1
}

"$repo_root/scripts/build.zsh"

stage=$(mktemp -d "${TMPDIR:-/tmp}/tailport-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT

darwin_dir="$stage/$darwin_name"
mkdir -p "$darwin_dir"
install -m 0755 "$dist_dir/tailport-darwin" "$darwin_dir/tailport"
install -m 0755 "$repo_root/scripts/install.sh" "$darwin_dir/install.sh"
install -m 0644 "$repo_root/README.md" "$darwin_dir/README.md"
install -m 0644 "$repo_root/LICENSE" "$darwin_dir/LICENSE"
install -m 0755 "$dist_dir/tailport-darwin" "$dist_dir/$darwin_name"

windows_dir="$stage/$windows_name"
mkdir -p "$windows_dir"
install -m 0644 "$dist_dir/tailport-windows.ps1" "$windows_dir/tailport.ps1"
install -m 0644 "$repo_root/scripts/install.ps1" "$windows_dir/install.ps1"
install -m 0644 "$repo_root/README.md" "$windows_dir/README.md"
install -m 0644 "$repo_root/LICENSE" "$windows_dir/LICENSE"
install -m 0644 "$dist_dir/tailport-windows.ps1" "$dist_dir/$windows_script_name"

source_dir="$stage/$source_name"
mkdir -p \
  "$source_dir/.github/workflows" \
  "$source_dir/src" \
  "$source_dir/scripts" \
  "$source_dir/tests"
install -m 0644 "$repo_root/.gitignore" "$source_dir/.gitignore"
install -m 0644 "$repo_root/.github/workflows/ci.yml" "$source_dir/.github/workflows/ci.yml"
install -m 0644 "$repo_root/LICENSE" "$source_dir/LICENSE"
install -m 0644 "$repo_root/Makefile" "$source_dir/Makefile"
install -m 0644 "$repo_root/README.md" "$source_dir/README.md"
install -m 0644 "$repo_root/VERSION" "$source_dir/VERSION"
install -m 0755 "$repo_root/src/tailport.zsh" "$source_dir/src/tailport.zsh"
install -m 0644 "$repo_root/src/tailport.ps1" "$source_dir/src/tailport.ps1"
install -m 0755 "$repo_root/scripts/build.zsh" "$source_dir/scripts/build.zsh"
install -m 0644 "$repo_root/scripts/build-windows.ps1" "$source_dir/scripts/build-windows.ps1"
install -m 0755 "$repo_root/scripts/install.sh" "$source_dir/scripts/install.sh"
install -m 0644 "$repo_root/scripts/install.ps1" "$source_dir/scripts/install.ps1"
install -m 0755 "$repo_root/scripts/package.zsh" "$source_dir/scripts/package.zsh"
install -m 0755 "$repo_root/tests/tailport_test.zsh" "$source_dir/tests/tailport_test.zsh"
install -m 0644 "$repo_root/tests/tailport_windows_test.ps1" "$source_dir/tests/tailport_windows_test.ps1"

tar -czf "$dist_dir/$darwin_archive_name" -C "$stage" "$darwin_name"
(
  cd "$stage"
  zip -qr "$dist_dir/$windows_archive_name" "$windows_name"
)
tar -czf "$dist_dir/$source_archive_name" -C "$stage" "$source_name"
(
  cd "$dist_dir"
  shasum -a 256 \
    "$darwin_name" \
    "$darwin_archive_name" \
    "$windows_script_name" \
    "$windows_archive_name" \
    "$source_archive_name" > SHA256SUMS
)

print -- "Packaged dist/$darwin_name"
print -- "Packaged dist/$darwin_archive_name"
print -- "Packaged dist/$windows_script_name"
print -- "Packaged dist/$windows_archive_name"
print -- "Packaged dist/$source_archive_name"
print -- "Wrote dist/SHA256SUMS"
