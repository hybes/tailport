#!/bin/zsh
# Builds, signs, notarises and publishes the version in VERSION as a GitHub release.
# The Mac and Windows apps check this release for updates.
#
# Usage: scripts/publish.zsh [--dry-run] [release-notes.md]
#   --dry-run                builds and checks everything, but does not tag or publish
#   TAILPORT_SIGN_IDENTITY   default: this keychain's Developer ID Application identity for the team below
#   TAILPORT_NOTARY_PROFILE  notarytool profile (default: "notary", shared by every project on this Mac)
#   TAILPORT_NOTARY_KEY_ID   instead of a profile, an App Store Connect API key ID, with TAILPORT_NOTARY_ISSUER
#                            and optionally TAILPORT_NOTARY_KEY (default ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8)
set -eu
setopt pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"
version=$(< VERSION)
tag="v$version"
team=BBU4YNR4U3
dry_run=false
notes=""
for argument in "$@"; do
  case $argument in
    --dry-run) dry_run=true ;;
    *) notes=$argument ;;
  esac
done

fail() { print -u2 -- "publish: $1"; exit 1; }

[[ -z $notes || -f $notes ]] || fail "release notes not found: $notes"
command -v jq >/dev/null || fail "jq is required: brew install jq"
command -v gh >/dev/null || fail "the GitHub CLI is required: brew install gh"
gh auth status >/dev/null 2>&1 || fail "sign in to GitHub first: gh auth login"

if ! $dry_run; then
  [[ -z $(git status --porcelain) ]] || fail "commit or stash your changes first"
  [[ $(git branch --show-current) == main ]] || fail "publish from main"
  git fetch --quiet origin main --tags
  [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || fail "main differs from origin/main; push or pull first"
  ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "$tag already exists. Change VERSION first"
  ! gh release view "$tag" >/dev/null 2>&1 || fail "release $tag already exists on GitHub"
fi

identity=${TAILPORT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
  sed -n "s/.*\"\(Developer ID Application: .*($team)\)\"/\1/p" | head -1)}
[[ -n $identity ]] || fail "no Developer ID Application certificate for team $team in the keychain"
# Notarise with the shared "notary" profile, or an App Store Connect API key named by TAILPORT_NOTARY_KEY_ID.
if [[ -n ${TAILPORT_NOTARY_KEY_ID:-} && -z ${TAILPORT_NOTARY_PROFILE:-} ]]; then
  key=${TAILPORT_NOTARY_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_$TAILPORT_NOTARY_KEY_ID.p8}
  xcrun notarytool history --key "$key" --key-id "$TAILPORT_NOTARY_KEY_ID" \
    --issuer "${TAILPORT_NOTARY_ISSUER:?set TAILPORT_NOTARY_ISSUER for the API key}" >/dev/null 2>&1 ||
    fail "Apple did not accept the API key $TAILPORT_NOTARY_KEY_ID with issuer $TAILPORT_NOTARY_ISSUER"
else
  export TAILPORT_NOTARY_PROFILE=${TAILPORT_NOTARY_PROFILE:-notary}
  xcrun notarytool history --keychain-profile "$TAILPORT_NOTARY_PROFILE" >/dev/null 2>&1 ||
    fail "no notarisation credentials in the \"$TAILPORT_NOTARY_PROFILE\" profile. Store an App Store Connect API key once:
  xcrun notarytool store-credentials notary --key ~/.appstoreconnect/private_keys/AuthKey_<KEY ID>.p8 --key-id <KEY ID> --issuer <ISSUER ID>"
fi

# Updates for the Windows app come from this release too, so it must include the Windows app.
if ! command -v "${DOTNET:-dotnet}" >/dev/null; then
  [[ -x $HOME/.dotnet/dotnet ]] || fail "the .NET 10 SDK is required to build the Windows app"
  export DOTNET="$HOME/.dotnet/dotnet"
fi

TAILPORT_SIGN_IDENTITY=$identity make release

spctl --assess --type execute dist/Tailport.app || fail "Gatekeeper rejected dist/Tailport.app"
xcrun stapler validate -q dist/Tailport.app || fail "dist/Tailport.app has no notarisation ticket"
assets=(dist/tailport-$version-*(.N) dist/SHA256SUMS)
for required in macos.zip windows-app-x64.zip windows-app-arm64.zip darwin.tar.gz windows.zip source.tar.gz; do
  [[ -f dist/tailport-$version-$required ]] || fail "dist/tailport-$version-$required is missing"
done
(cd dist && shasum -a 256 -c SHA256SUMS >/dev/null) || fail "SHA256SUMS does not match the files in dist/"

if $dry_run; then
  print -- "\nDry run: Tailport $version is built, signed and notarised. Nothing was tagged or published."
  printf '  %s\n' "${assets[@]}"
  exit 0
fi

git tag -a "$tag" -m "Tailport $version"
git push origin "$tag"
note_flags=(--generate-notes)
[[ -n $notes ]] && note_flags=(--notes-file "$notes")
gh release create "$tag" --verify-tag --title "Tailport $version" "${note_flags[@]}" "${assets[@]}"
print -- "\nPublished $(gh release view "$tag" --json url -q .url)"
