set -u
ports="@PORTS@"
if [ "$(uname -s)" = Darwin ]; then
  dev=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }')
  addr=$(ifconfig "$dev" 2>/dev/null | awk '/inet / { print $2 "/" $4; exit }')
else
  dev=$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
  addr=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{ print $4; exit }')
fi
[ -n "$addr" ] || { echo 'tailport: no local network found' >&2; exit 3; }
# Accepts 192.168.1.5/24 or macOS's 192.168.1.5/0xffffff00. Scans at most a /22.
hosts=$(echo "$addr" | awk -F/ '{
  split($1, o, "."); self = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
  m = $2; bits = 0
  if (m ~ /^0x/) { m = substr(m, 3); for (i = 1; i <= length(m); i++) { d = index("0123456789abcdef", tolower(substr(m, i, 1))) - 1; for (b = 3; b >= 0; b--) if (int(d / 2 ^ b) % 2) bits++ } }
  else bits = m + 0
  if (bits < 22) bits = 24
  size = 2 ^ (32 - bits); base = self - self % size
  printf "S %d.%d.%d.%d/%d\n", int(base / 16777216), int(base / 65536) % 256, int(base / 256) % 256, base % 256, bits > "/dev/stderr"
  for (h = base + 1; h < base + size - 1; h++) if (h != self) printf "%d.%d.%d.%d\n", int(h / 16777216), int(h / 65536) % 256, int(h / 256) % 256, h % 256
}' 2>&1)
echo "$hosts" | grep '^S '
targets=$(echo "$hosts" | grep -v '^S ')
for ip in $targets; do
  if [ "$(uname -s)" = Darwin ]; then ping -c 1 -t 1 -q "$ip" >/dev/null 2>&1 &
  else ping -c 1 -W 1 -q "$ip" >/dev/null 2>&1 & fi
done
wait
if [ "$(uname -s)" = Darwin ]; then
  found=$(arp -an -i "$dev" 2>/dev/null | awk '$4 ~ /:/ { gsub(/[()]/, "", $2); print $2, $4 }')
else
  found=$(ip -4 neigh show dev "$dev" 2>/dev/null | awk '$2 == "lladdr" && $NF != "FAILED" && $NF != "INCOMPLETE" { print $1, $3 }')
fi
echo "$found" | { while read -r ip mac; do
  [ -n "$ip" ] || continue
  echo "$targets" | grep -qx "$ip" || continue
  (name=""
   if command -v getent >/dev/null 2>&1; then name=$(timeout 2 getent hosts "$ip" 2>/dev/null | awk '{ print $2; exit }')
   elif [ -x /usr/bin/dig ]; then name=$(/usr/bin/dig +short +time=1 +tries=1 -x "$ip" 2>/dev/null | sed -n '1s/\.$//p'); fi
   echo "H $ip $mac $name") &
  # Each device is probed in batches of 12 ports, keeping the number of processes small.
  (n=0
   for port in $ports; do
     if [ "$(uname -s)" = Darwin ]; then (nc -z -G 1 -w 1 "$ip" "$port" >/dev/null 2>&1 && echo "P $ip $port") &
     else (nc -z -w 1 "$ip" "$port" >/dev/null 2>&1 && echo "P $ip $port") & fi
     n=$((n + 1)); [ $((n % 12)) -eq 0 ] && wait
   done
   wait) &
done
wait; }
