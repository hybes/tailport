#!/bin/zsh

set -eu
setopt pipefail

repo_root="${0:A:h:h}"
artifact="${1:-$repo_root/dist/tailport}"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/tailport-tests.XXXXXX")
mockbin="$tmpdir/bin"
mkdir -p "$mockbin"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
  print -u2 -- "not ok - $*"
  exit 1
}

assert_line() {
  local expected="$1"
  local file="$2"
  grep -Fqx -- "$expected" "$file" || fail "missing '$expected' in $file"
}

real_jq=$(command -v jq) || fail "jq is required to run the tests"
ln -s "$real_jq" "$mockbin/jq"

cat > "$mockbin/tailscale" <<'EOF'
#!/bin/zsh
print -r -- '{
  "CurrentTailnet": {"MagicDNSEnabled": true},
  "Peer": {
    "nodekey:test": {
      "HostName": "BH Mac mini",
      "DNSName": "bh-mm.example.ts.net.",
      "OS": "macOS",
      "Online": true,
      "TailscaleIPs": ["100.64.0.2"]
    }
  }
}'
EOF

cat > "$mockbin/ssh" <<'EOF'
#!/bin/zsh
printf '%s\n' "$@" > "$TAILPORT_TEST_SSH_ARGS"
EOF

chmod +x "$mockbin/tailscale" "$mockbin/ssh"
test_path="$mockbin:/usr/bin:/bin"

expected_version=$(< "$repo_root/VERSION")
version=$($artifact --version)
[[ "$version" = "tailport $expected_version" ]] || fail "unexpected version: $version"
print -- 'ok - release version'

# Direct invocation builds every requested forward in one SSH command.
args_file="$tmpdir/direct-args"
PATH="$test_path" TAILPORT_TEST_SSH_ARGS="$args_file" \
  "$artifact" bh-mm 5173,3005,8080:3000 > "$tmpdir/direct-output"
assert_line '127.0.0.1:5173:localhost:5173' "$args_file"
assert_line '127.0.0.1:3005:localhost:3005' "$args_file"
assert_line '127.0.0.1:8080:localhost:3000' "$args_file"
assert_line 'bh-mm' "$args_file"
print -- 'ok - direct forwarding and port remapping'

# The fallback picker resolves the selected Tailscale peer and prompts for ports.
args_file="$tmpdir/picker-args"
printf '1\n5173,3005\n' | \
  PATH="$test_path" TAILPORT_TEST_SSH_ARGS="$args_file" \
  "$artifact" > "$tmpdir/picker-output"
assert_line '127.0.0.1:5173:localhost:5173' "$args_file"
assert_line '127.0.0.1:3005:localhost:3005' "$args_file"
assert_line 'bh-mm' "$args_file"
print -- 'ok - interactive peer selection'

# Invalid ports fail before SSH is invoked.
if PATH="$test_path" TAILPORT_TEST_SSH_ARGS="$tmpdir/invalid-args" \
  "$artifact" bh-mm 70000 > "$tmpdir/invalid-output" 2> "$tmpdir/invalid-error"; then
  fail 'out-of-range port was accepted'
fi
assert_line 'tailport: local port out of range: 70000' "$tmpdir/invalid-error"
[[ ! -e "$tmpdir/invalid-args" ]] || fail 'SSH ran for an invalid port'
print -- 'ok - invalid port rejection'
