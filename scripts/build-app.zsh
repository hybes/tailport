#!/bin/zsh
set -eu
setopt pipefail

repo_root="${0:A:h:h}"
version=$(< "$repo_root/VERSION")
sdk=$(xcrun --sdk macosx --show-sdk-path)
app="$repo_root/dist/Tailport.app"
build_dir="${TAILPORT_BUILD_DIR:-$repo_root/macos/.build}"
stage=$(mktemp -d "${TMPDIR:-/tmp}/tailport-app.XXXXXX")
trap 'rm -rf "$stage"' EXIT
staged_app="$stage/Tailport.app"

swift build --package-path "$repo_root/macos" --scratch-path "$build_dir" -c release --sdk "$sdk" \
  -Xswiftc -Xclang-linker -Xswiftc -isysroot \
  -Xswiftc -Xclang-linker -Xswiftc "$sdk"
binary_dir=$(swift build --package-path "$repo_root/macos" --scratch-path "$build_dir" -c release --show-bin-path)
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
install -m 0755 "$binary_dir/Tailport" "$staged_app/Contents/MacOS/Tailport"
install -m 0755 "$binary_dir/TailportTunnel" "$staged_app/Contents/MacOS/TailportTunnel"
sed "s/@TAILPORT_VERSION@/$version/g" "$repo_root/macos/Info.plist" > "$staged_app/Contents/Info.plist"
swift "$repo_root/macos/make-icon.swift" "$staged_app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$staged_app/Contents/MacOS/TailportTunnel"
codesign --force --sign - "$staged_app"
mkdir -p "$repo_root/dist"
ditto --norsrc --noextattr "$staged_app" "$app"
# File Provider can add Finder metadata when the bundle is copied into Documents.
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
codesign --verify --deep --strict "$app"
print -- "Built $app"
