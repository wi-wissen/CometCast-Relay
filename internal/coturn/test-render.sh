#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Tests deploy/coturn/render.sh with good and hostile inputs, in a temporary copy of the
# deploy/ layout (the real deploy/.env and secrets are never touched).
# Run:  sh deploy/coturn/test-render.sh      (also run by `cargo test -p cc-server`)
set -u

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
count=0

setup() {   # fresh layout; $1 = turn_secret file content (printf format)
  rm -rf "$work/deploy"
  mkdir -p "$work/deploy/coturn" "$work/deploy/secrets"
  cp "$here/render.sh" "$here/turnserver.conf.template" "$work/deploy/coturn/"
  printf "$1" > "$work/deploy/secrets/turn_secret"
  cat > "$work/deploy/.env" <<'EOF'
TURN_REALM=turn.example.org
TURN_EXTERNAL_IP=203.0.113.10
TURN_RELAY_IP=10.0.0.5
TURN_MIN_PORT=49160
TURN_MAX_PORT=49200
EOF
}
good_secret='0123456789abcdef0123456789abcdef\n'

setting() {   # set KEY to VALUE in the test .env (VALUE taken literally)
  grep -v "^$1=" "$work/deploy/.env" > "$work/env.new"
  printf '%s=%s\n' "$1" "$2" >> "$work/env.new"
  mv "$work/env.new" "$work/deploy/.env"
}

run() { sh "$work/deploy/coturn/render.sh" > "$work/out.txt" 2>&1; }

ok() {      # ok NAME : render must succeed
  count=$((count + 1))
  if run; then :; else echo "FAIL (should work): $1"; sed 's/^/   /' "$work/out.txt"; fails=$((fails + 1)); fi
}
bad() {     # bad NAME : render must fail, and must not leave a config behind
  count=$((count + 1))
  if run; then
    echo "FAIL (should be refused): $1"; fails=$((fails + 1))
  elif [ -e "$work/deploy/coturn/turnserver.conf" ]; then
    echo "FAIL (refused but left a config): $1"; fails=$((fails + 1))
  fi
}
has() {     # has NAME TEXT : the rendered file contains this exact line
  count=$((count + 1))
  if ! grep -Fxq -- "$2" "$work/deploy/coturn/turnserver.conf"; then
    echo "FAIL (line missing): $1: $2"; fails=$((fails + 1))
  fi
}

# --- a good render -------------------------------------------------------------------
setup "$good_secret"
ok "good input"
has "min port" "min-port=49160"
has "max port" "max-port=49200"
has "secret" "static-auth-secret=0123456789abcdef0123456789abcdef"
has "external ip" "external-ip=203.0.113.10"
has "extra denied range: Teredo" "denied-peer-ip=2001::-2001:0:ffff:ffff:ffff:ffff:ffff:ffff"
has "extra denied range: discard" "denied-peer-ip=100::-100::ffff:ffff:ffff:ffff"
has "extra denied range: local NAT64" "denied-peer-ip=64:ff9b:1::-64:ff9b:1:ffff:ffff:ffff:ffff:ffff"
has "extra denied range: 6to4 relay anycast" "denied-peer-ip=192.88.99.0-192.88.99.255"
has "extra denied range: documentation 2001:db8::/32" "denied-peer-ip=2001:db8::-2001:db8:ffff:ffff:ffff:ffff:ffff:ffff"
has "extra denied range: ORCHID 2001:10::/28" "denied-peer-ip=2001:10::-2001:1f:ffff:ffff:ffff:ffff:ffff:ffff"
has "extra denied range: ORCHIDv2 2001:20::/28" "denied-peer-ip=2001:20::-2001:2f:ffff:ffff:ffff:ffff:ffff:ffff"
has "extra denied range: 5f00::/16" "denied-peer-ip=5f00::-5f00:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
has "extra denied range: 3fff::/20" "denied-peer-ip=3fff::-3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff"
# The range 41 ports wide (49160-49200) gives 80 % = 32; user-quota and bandwidth lines exist.
has "total quota below the port count" "total-quota=32"
has "user quota" "user-quota=24"
has "max-bps" "max-bps=750000"
has "bps-capacity" "bps-capacity=125000000"
count=$((count + 1)); grep -Eq '^denied-peer-ip=::(-|/)' "$work/deploy/coturn/turnserver.conf" && { echo "FAIL: a ::-based denied-peer-ip line (breaks all IPv4 peers in coturn 4.18.0)"; fails=$((fails + 1)); }
count=$((count + 1)); grep -q '@[A-Z0-9_]*@' "$work/deploy/coturn/turnserver.conf" && { echo "FAIL: unreplaced @PLACEHOLDER@ left"; grep -n '@[A-Z0-9_]*@' "$work/deploy/coturn/turnserver.conf"; fails=$((fails + 1)); }
has "no listening-ip set" "# listening-ip not set: coturn listens on every address of the host"
mode=$(stat -c %a "$work/deploy/coturn/turnserver.conf" 2>/dev/null || stat -f %Lp "$work/deploy/coturn/turnserver.conf")
count=$((count + 1)); [ "$mode" = 600 ] || { echo "FAIL: new file mode is $mode, want 600"; fails=$((fails + 1)); }
# Optional listening address, NAT form "public/private", small and large ranges.
setup "$good_secret"; setting TURN_LISTENING_IP 10.0.0.5
ok "listening ip"
has "listening ip line" "listening-ip=10.0.0.5"
setup "$good_secret"; setting TURN_LISTENING_IP ''
ok "empty listening ip is the same as unset"
has "empty listening ip" "# listening-ip not set: coturn listens on every address of the host"
for ip in 0.0.0.0 :: 127.0.0.1 999.1.1.1 'a;b' ff02::1 10.0.0.5/24 '1.2.3.4 x'; do
  setup "$good_secret"; setting TURN_LISTENING_IP "$ip"; bad "listening ip '$ip'"
done
setup "$good_secret"; setting TURN_EXTERNAL_IP 203.0.113.10/10.0.0.5
ok "NAT form public/private"
has "NAT external-ip" "external-ip=203.0.113.10/10.0.0.5"
setup "$good_secret"; setting TURN_EXTERNAL_IP 2001:db8::10/10.0.0.5; ok "NAT form with an IPv6 public part"
for ip in '203.0.113.10/' '/10.0.0.5' '203.0.113.10/10.0.0.5/1' '203.0.113.10/0.0.0.0' '203.0.113.10/x' '203.0.113.10/24' '999.1.1.1/10.0.0.5' '203.0.113.10/10.0.0.5;id'; do
  setup "$good_secret"; setting TURN_EXTERNAL_IP "$ip"; bad "external ip '$ip'"
done
setup "$good_secret"; setting TURN_MIN_PORT 50000; setting TURN_MAX_PORT 50000
ok "one port"
has "total quota is at least 1" "total-quota=1"
setup "$good_secret"; setting TURN_MIN_PORT 49160; setting TURN_MAX_PORT 49660
ok "default range"
has "total quota 80 percent of 501 ports" "total-quota=400"
# CRLF secret file and IPv6 addresses are fine.
setup '0123456789abcdef0123456789abcdef\r\n'
setting TURN_EXTERNAL_IP 2001:db8::10
setting TURN_RELAY_IP 2001:db8:0:1:2:3:4:5
ok "CRLF secret and IPv6 addresses"
has "secret without CR" "static-auth-secret=0123456789abcdef0123456789abcdef"
setup '0123456789abcdef0123456789abcdef'
ok "secret without final newline"

# --- an existing output file with open permissions is tightened ------------------------
setup "$good_secret"
echo "old" > "$work/deploy/coturn/turnserver.conf"
chmod 644 "$work/deploy/coturn/turnserver.conf"
ok "re-render over an old world-readable file"
mode=$(stat -c %a "$work/deploy/coturn/turnserver.conf" 2>/dev/null || stat -f %Lp "$work/deploy/coturn/turnserver.conf")
count=$((count + 1)); [ "$mode" = 600 ] || { echo "FAIL: old file mode is $mode after render, want 600"; fails=$((fails + 1)); }
count=$((count + 1)); ls "$work/deploy/coturn" | grep -q '^\.turnserver' && { echo "FAIL: temporary file left behind"; fails=$((fails + 1)); }

# --- ports ---------------------------------------------------------------------------
for p in 0 65536 99999 123456 abc 08 -1 '1 2' 1.5 ''; do
  setup "$good_secret"; setting TURN_MIN_PORT "$p"; bad "min port '$p'"
  setup "$good_secret"; setting TURN_MAX_PORT "$p"; bad "max port '$p'"
done
setup "$good_secret"; setting TURN_MIN_PORT 50000; setting TURN_MAX_PORT 49999; bad "min above max"
setup "$good_secret"; setting TURN_MIN_PORT 1; setting TURN_MAX_PORT 65535; ok "full port range"
setup "$good_secret"; setting TURN_MIN_PORT 49160; setting TURN_MAX_PORT 49160; ok "min equals max"

# --- addresses -----------------------------------------------------------------------
for ip in 999.1.1.1 1.2.3 1.2.3.4.5 1.2.3.256 01.2.3.4 1..2.3 0.0.0.0 127.0.0.1 224.0.0.1 255.0.0.1 255.255.255.255 \
          :: ::1 ff02::1 1:2:3:4:5:6:7 1:2:3:4:5:6:7:8:9 1::2::3 :::1 1:2 12345::1 gggg::1 \
          :1:2:3:4:5:6:7 1:2:3:4:5:6:7: 2001:db8::/32 ::ffff:1.2.3.4 'a;b' '1.2.3.4 x' ''; do
  setup "$good_secret"; setting TURN_EXTERNAL_IP "$ip"; bad "external ip '$ip'"
  setup "$good_secret"; setting TURN_RELAY_IP "$ip"; bad "relay ip '$ip'"
done
for ip in 8.8.8.8 10.0.0.5 223.255.255.254 2001:db8::1 fe80::1 1:2:3:4:5:6:7:8 ::2 1::; do
  setup "$good_secret"; setting TURN_EXTERNAL_IP "$ip"; ok "external ip '$ip'"
done

# --- realm ---------------------------------------------------------------------------
for r in 'a b' 'a;b' 'a$(id)' 'a&b' '' 'a|b'; do
  setup "$good_secret"; setting TURN_REALM "$r"; bad "realm '$r'"
done

# --- the secret ----------------------------------------------------------------------
setup 'abcdefghijklmnop\nqrstuvwxyz012345\n';        bad "two-line secret is not merged"
setup 'abcdefghijklmnopqrstuvwxyz012345\n\n';        bad "secret with an empty second line"
setup 'abcdefghijklmnopqrstuvwxyz012345\nx\n';       bad "secret with a trailing extra line"
setup '\n';                                          bad "empty secret line"
setup '';                                            bad "empty secret file"
setup 'short\n';                                     bad "short secret"
setup 'abcdefghijklmnop qrstuvwxyz\n';               bad "secret with a space"
setup 'abcdefghijklmnop\rqrstuvwxyz0123\n';          bad "secret with a CR inside"
setup 'abcdefghijklmnop\000qrstuvwxyz0123\n';        bad "secret with a NUL byte"
setup 'abcdefghijklmnopqrstuvwxyz$(id)\n';           bad "secret with shell syntax"
setup 'abcdefghijklmnopqrstuvwxyz&\\\\0123\n';        bad "secret with & and backslash"
setup 'abcdefghijklmnopqrstuvwxyz;rm\n';             bad "secret with a semicolon"

# --- missing files -------------------------------------------------------------------
setup "$good_secret"; rm "$work/deploy/.env"; bad "missing .env"
setup "$good_secret"; rm "$work/deploy/secrets/turn_secret"; bad "missing secret"

# --- .env is data, not code ------------------------------------------------------------
setup "$good_secret"
printf 'TURN_REALM=$(touch %s/pwned)\n' "$work" >> "$work/deploy/.env"
bad "command substitution in .env"
count=$((count + 1)); [ -e "$work/pwned" ] && { echo "FAIL: .env value was executed"; fails=$((fails + 1)); }

echo "render.sh tests: $count checks, $fails failed"
[ "$fails" -eq 0 ]
