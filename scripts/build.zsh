#!/bin/zsh

set -eu
setopt pipefail

repo_root="${0:A:h:h}"
version=$(< "$repo_root/VERSION")
output_dir="$repo_root/dist"

[[ "$version" == <->.<->.<-> ]] || {
  print -u2 -- "build: VERSION must contain a semantic version (for example, 0.1.0)"
  exit 1
}

build_artifact() {
  local source_file="$1"
  local output_file="$2"
  local temporary

  grep -Fq '@TAILPORT_VERSION@' "$source_file" || {
    print -u2 -- "build: version placeholder is missing from ${source_file#$repo_root/}"
    exit 1
  }

  temporary=$(mktemp "${TMPDIR:-/tmp}/tailport-build.XXXXXX")
  sed "s/@TAILPORT_VERSION@/$version/g" "$source_file" > "$temporary"
  grep -Fq '@TAILPORT_VERSION@' "$temporary" && {
    rm -f "$temporary"
    print -u2 -- "build: version placeholder was not replaced"
    exit 1
  }

  chmod 0755 "$temporary"
  mv "$temporary" "$output_file"
}

mkdir -p "$output_dir"
build_artifact "$repo_root/src/tailport.zsh" "$output_dir/tailport-darwin"
build_artifact "$repo_root/src/tailport.ps1" "$output_dir/tailport-windows.ps1"

print -- "Built dist/tailport-darwin ($version)"
print -- "Built dist/tailport-windows.ps1 ($version)"
