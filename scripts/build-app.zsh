#!/bin/zsh
# Builds dist/Tailport.app.
#   TAILPORT_ARCHS          architectures to build, such as "arm64 x86_64" (default: this Mac's)
#   TAILPORT_SIGN_IDENTITY  codesigning identity; Developer ID builds use the hardened runtime (default: ad-hoc "-")
set -eu
setopt pipefail

repo_root="${0:A:h:h}"
version=$(< "$repo_root/VERSION")
sdk=$(xcrun --sdk macosx --show-sdk-path)
app="$repo_root/dist/Tailport.app"
build_dir="${TAILPORT_BUILD_DIR:-$repo_root/macos/.build}"
archs=(${=TAILPORT_ARCHS:-$(uname -m)})
identity="${TAILPORT_SIGN_IDENTITY:--}"
stage=$(mktemp -d "${TMPDIR:-/tmp}/tailport-app.XXXXXX")
trap 'rm -rf "$stage"' EXIT
staged_app="$stage/Tailport.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"

# Build each architecture in turn and keep its binaries, since some Swift build systems reuse one output folder.
for arch in $archs; do
  flags=(--package-path "$repo_root/macos" --scratch-path "$build_dir" -c release --sdk "$sdk" --triple "$arch-apple-macosx14.0"
         -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk")
  swift build "${flags[@]}"
  bin=$(swift build "${flags[@]}" --show-bin-path)
  mkdir -p "$stage/$arch"
  cp "$bin/Tailport" "$bin/TailportTunnel" "$stage/$arch/"
done
for product in Tailport TailportTunnel; do
  slices=()
  for arch in $archs; do slices+=("$stage/$arch/$product"); done
  lipo -create "${slices[@]}" -output "$staged_app/Contents/MacOS/$product"
  chmod 0755 "$staged_app/Contents/MacOS/$product"
done

sed "s/@TAILPORT_VERSION@/$version/g" "$repo_root/macos/Info.plist" > "$staged_app/Contents/Info.plist"
swift "$repo_root/macos/make-icon.swift" "$staged_app/Contents/Resources/AppIcon.icns"
sign=(codesign --force --sign "$identity")
[[ $identity != - ]] && sign+=(--options runtime --timestamp)
"${sign[@]}" "$staged_app/Contents/MacOS/TailportTunnel"
"${sign[@]}" "$staged_app"
mkdir -p "$repo_root/dist"
rm -rf "$app"
ditto --norsrc --noextattr "$staged_app" "$app"
# File Provider can add Finder metadata when the bundle is copied into Documents.
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
codesign --verify --deep --strict "$app"
print -- "Built $app ($archs, signed with ${identity/#-/an ad-hoc signature})"
