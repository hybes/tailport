#!/bin/zsh

set -u
setopt pipefail

TAILPORT_VERSION='@TAILPORT_VERSION@'

usage() {
  cat <<'EOF'
Usage: tailport [options] [machine] [ports]

Pick an online Tailscale machine and forward its loopback ports to this Mac.

Arguments:
  machine             MagicDNS name, SSH alias, IP, or user@machine
  ports               Comma-separated ports, e.g. 5173,3005
                      Use LOCAL:REMOTE to remap, e.g. 8080:3000

Options:
  -u, --user USER     SSH user (or set TAILPORT_USER)
  -a, --all           Include offline Tailscale peers in the picker
  -V, --version       Show the installed version
  -h, --help          Show this help

Examples:
  tailport
  tailport bh-mm 5173,3005
  tailport -u ben bh-mm 5173,8080:3005
EOF
}

die() {
  print -u2 -- "tailport: $*"
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

ssh_user="${TAILPORT_USER:-}"
include_offline=false
typeset -a positional

while (( $# > 0 )); do
  case "$1" in
    -u|--user)
      (( $# >= 2 )) || die "$1 requires a username"
      ssh_user="$2"
      shift 2
      ;;
    -a|--all)
      include_offline=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -V|--version)
      print -- "tailport $TAILPORT_VERSION"
      exit 0
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

(( ${#positional} <= 2 )) || die "expected at most a machine and a port list"

need tailscale
need jq
need ssh

machine="${positional[1]-}"
ports_input="${positional[2]-}"

if [[ -z "$machine" ]]; then
  all_json=false
  $include_offline && all_json=true

  if ! peer_rows=$(tailscale status --json | jq -r --argjson all "$all_json" '
    .CurrentTailnet.MagicDNSEnabled as $magic_dns
    | [
        .Peer[]
        | select(.Online == true or $all)
        | {
            name: ((.DNSName // .HostName // "unknown") | rtrimstr(".") | split(".")[0]),
            host: (.HostName // "unknown"),
            os: (.OS // "unknown"),
            state: (if .Online then "online" else "offline" end),
            target: (
              if $magic_dns and (.DNSName // "") != ""
              then ((.DNSName | rtrimstr(".")) | split(".")[0])
              else (.TailscaleIPs[0] // .HostName)
              end
            )
          }
      ]
    | sort_by(.name | ascii_downcase)
    | .[]
    | [.name, .host, .os, .state, .target]
    | @tsv
  '); then
    die "could not read the Tailscale peer list"
  fi

  [[ -n "$peer_rows" ]] || die "no matching Tailscale peers found"

  # fzf expands raw tabs relative to each field's current position, which makes
  # columns drift when names have different lengths. Format one display field
  # identically for the header and every row, keeping the SSH target hidden in
  # a second tab-separated field.
  picker_rows=$(while IFS=$'\t' read -r name host os state target; do
    printf '%-18.18s  %-24.24s  %-8.8s  %-7.7s\t%s\n' \
      "$name" "$host" "$os" "$state" "$target"
  done <<< "$peer_rows")
  picker_header=$(printf '%-18s  %-24s  %-8s  %-7s' \
    'TAILNET NAME' 'HOSTNAME' 'OS' 'STATE')

  if command -v fzf >/dev/null 2>&1; then
    selected=$(print -r -- "$picker_rows" | fzf \
      --delimiter=$'\t' \
      --with-nth=1 \
      --height=60% \
      --layout=reverse \
      --border \
      --prompt='Tailscale machine > ' \
      --header="$picker_header") || exit 130
  else
    typeset -a rows
    rows=("${(@f)picker_rows}")
    print -- "Tailscale machines:"
    print -- "     $picker_header"
    integer i=1
    for row in "${rows[@]}"; do
      display=$(print -r -- "$row" | cut -f1)
      printf '  %2d) %s\n' "$i" "$display"
      (( i++ ))
    done
    read "choice?Machine number: "
    [[ "$choice" == <-> ]] || die "invalid selection"
    (( choice >= 1 && choice <= ${#rows} )) || die "selection out of range"
    selected="${rows[$choice]}"
  fi

  machine=$(print -r -- "$selected" | cut -f2)
  [[ -n "$machine" ]] || die "selected peer has no usable address"
fi

if [[ -z "$ports_input" ]]; then
  read "ports_input?Ports (comma-separated, e.g. 5173,3005): "
fi

ports_input="${ports_input//[[:space:]]/}"
[[ -n "$ports_input" ]] || die "no ports supplied"

typeset -a port_specs ssh_args summary
typeset -A claimed_local_ports
port_specs=("${(@s:,:)ports_input}")
ssh_args=(-N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3)

for spec in "${port_specs[@]}"; do
  [[ -n "$spec" ]] || die "empty port in list: $ports_input"

  if [[ "$spec" == *:* ]]; then
    local_raw="${spec%%:*}"
    remote_raw="${spec#*:}"
    [[ "$remote_raw" != *:* ]] || die "invalid mapping: $spec"
  else
    local_raw="$spec"
    remote_raw="$spec"
  fi

  [[ "$local_raw" == <-> ]] || die "invalid local port: $local_raw"
  [[ "$remote_raw" == <-> ]] || die "invalid remote port: $remote_raw"

  integer local_port=$(( 10#$local_raw ))
  integer remote_port=$(( 10#$remote_raw ))
  (( local_port >= 1 && local_port <= 65535 )) || die "local port out of range: $local_raw"
  (( remote_port >= 1 && remote_port <= 65535 )) || die "remote port out of range: $remote_raw"
  [[ -z "${claimed_local_ports[$local_port]-}" ]] || die "local port repeated: $local_port"
  claimed_local_ports[$local_port]=1

  ssh_args+=(-L "127.0.0.1:${local_port}:localhost:${remote_port}")
  summary+=("localhost:${local_port} -> ${machine}:${remote_port}")
done

target="$machine"
if [[ -n "$ssh_user" && "$machine" != *@* ]]; then
  target="${ssh_user}@${machine}"
fi

print -- ""
print -- "Opening Tailscale SSH tunnel to ${target}:"
for line in "${summary[@]}"; do
  print -- "  $line"
done
print -- ""
print -- "Keep this window open; press Ctrl-C to close every forward."
print -- ""

exec ssh "${ssh_args[@]}" "$target"
