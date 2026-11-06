#!/bin/zsh
# Builds the Windows app as one self-contained Tailport.exe for x64 and ARM64, zipped in dist/.
set -eu
setopt pipefail

repo_root="${0:A:h:h}"
version=$(< "$repo_root/VERSION")
dotnet="${DOTNET:-dotnet}"
stage=$(mktemp -d "${TMPDIR:-/tmp}/tailport-windows-app.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$repo_root/dist"

for arch in x64 arm64; do
  name="tailport-$version-windows-app-$arch"
  "$dotnet" publish "$repo_root/windows/src/Tailport.App" -c Release -r "win-$arch" \
    -p:TailportVersion="$version" -o "$stage/$name" --nologo -v quiet
  install -m 0644 "$repo_root/README.md" "$stage/$name/README.md"
  install -m 0644 "$repo_root/LICENSE" "$stage/$name/LICENSE"
  rm -f "$repo_root/dist/$name.zip"
  (cd "$stage" && zip -qr "$repo_root/dist/$name.zip" "$name")
  print -- "Built dist/$name.zip"
done
