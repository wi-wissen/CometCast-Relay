#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Static consistency checks of the configuration files (no Docker, no network). Used by up.sh and CI.
# It cannot replace the server's own validation at start; it catches the mistakes that would
# otherwise show up as an outage: wrong mode, TURN section, missing origins, proxy address mismatch,
# STUN list that does not match the STUN service, a STUN service that could relay.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

toml=$ROOT/config/relay.toml
compose_file=$ROOT/compose.yaml
[ -f "$toml" ] || die "missing $toml"
[ -f "$compose_file" ] || die "missing $compose_file"

# Syntax check where the Python in use can read TOML (3.11+).
if have_cmd python3 && python3 -I -c 'import tomllib' 2>/dev/null; then
  if python3 -I -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$toml" 2>/dev/null; then
    ok "relay.toml is valid TOML"
  else
    fail "relay.toml is not valid TOML"
  fi
else
  warn "no Python with tomllib: TOML syntax not checked (the server checks it at start)"
fi

# Lines without comments, for the greps below. An array that is written over several lines
# (allowed_origins = [ ... ] with one entry per line) is joined into one line first.
active=$(sed -e 's/[[:space:]]*#.*$//' "$toml" | awk '
  joining { buf = buf " " $0; if ($0 ~ /\]/) { print buf; joining = 0; buf = "" } next }
  /=[[:space:]]*\[/ && !/\]/ { buf = $0; joining = 1; next }
  { print }
  END { if (joining) print buf }')

if grep -Eq '^mode[[:space:]]*=[[:space:]]*"open"[[:space:]]*$' <<<"$active"; then
  ok "mode = \"open\""
else
  fail "relay.toml: mode must be \"open\" for the public relay"
fi

if grep -Eq '^\[turn\]' <<<"$active"; then
  fail "relay.toml has a [turn] section: the server refuses it in open mode"
else
  ok "no [turn] section"
fi

if grep -Eq '^(secret|turn\.secret)[[:space:]]*=' <<<"$active"; then
  fail "relay.toml has an inline secret: use secret_file"
else
  ok "no inline secret"
fi
if grep -Eq '^secret_file[[:space:]]*=[[:space:]]*"/run/secrets/altcha_secret"' <<<"$active"; then
  ok "altcha secret comes from /run/secrets/altcha_secret"
else
  fail "relay.toml: altcha.secret_file must be \"/run/secrets/altcha_secret\" (compose secret)"
fi

origins=$(grep -E '^allowed_origins[[:space:]]*=' <<<"$active" || true)
if [ -z "$origins" ]; then
  fail "relay.toml: allowed_origins is not set (a public relay must list its web origins)"
else
  bad=0
  count=0
  while IFS= read -r entry; do
    count=$((count + 1))
    if [ "$entry" = '*' ]; then
      fail "relay.toml: allowed_origins \"*\" is refused in open mode"
      bad=1
    elif ! [[ $entry =~ ^https?://[^/\ ]+$ ]]; then
      fail "relay.toml: allowed_origins entry '$entry' is not of the form https://host[:port] (no path, no trailing slash)"
      bad=1
    fi
  done < <(grep -o '"[^"]*"' <<<"$origins" | tr -d '"')
  if [ "$count" -eq 0 ]; then
    fail "relay.toml: allowed_origins is empty"
  elif [ "$bad" -eq 0 ]; then
    ok "allowed_origins: $(grep -o '"[^"]*"' <<<"$origins" | tr '\n' ' ')"
  fi
fi

# Caddy's address in compose.yaml must be the trusted proxy in relay.toml.
caddy_ip=$(awk '/^[[:space:]]+ipv4_address:/ { print $2; exit }' "$compose_file")
subnet=$(awk '/^[[:space:]]+- subnet:/ { print $3; exit }' "$compose_file")
tp=$(grep -E '^trusted_proxies[[:space:]]*=' <<<"$active" || true)
if [ -z "$caddy_ip" ]; then
  fail "compose.yaml: no ipv4_address for caddy found"
elif [ -z "$tp" ]; then
  fail "relay.toml: network.trusted_proxies is not set (every client would look like the proxy)"
elif [ "$(grep -o '"[^"]*"' <<<"$tp" | tr -d '"')" != "$caddy_ip/32" ]; then
  fail "relay.toml trusted_proxies ($(grep -o '"[^"]*"' <<<"$tp" | tr '\n' ' ')) must be exactly \"$caddy_ip/32\" (Caddy's address in compose.yaml)"
else
  ok "trusted_proxies = $caddy_ip/32 matches Caddy's address in compose.yaml"
fi
# The address pool Docker hands out (ip_range) must NOT contain Caddy's fixed address: that is the real protection
# against another container on the backend network taking Caddy's address (the server trusts X-Forwarded-For from
# that address alone). Containers without a fixed address get one from ip_range only.
ip_range=$(awk '/^[[:space:]]+ip_range:/ { print $2; exit }' "$compose_file")
if [ -z "$subnet" ] || [ -z "$caddy_ip" ]; then
  : # reported above
elif [ -z "$ip_range" ]; then
  fail "compose.yaml: the backend network has no ip_range: Docker could hand Caddy's address ($caddy_ip) to another container (set ip_range to a part of $subnet that does not contain it)"
elif have_cmd python3; then
  if range_msg=$(python3 -I - "$caddy_ip" "$subnet" "$ip_range" <<'PY' 2>&1
import ipaddress, sys
caddy, subnet, pool = sys.argv[1:4]
try:
    c = ipaddress.ip_address(caddy)
    s = ipaddress.ip_network(subnet, strict=True)
    p = ipaddress.ip_network(pool, strict=True)
except ValueError as e:
    sys.exit("cannot parse the addresses: %s" % e)
if c not in s:
    sys.exit("caddy address %s is not in subnet %s" % (c, s))
if not p.subnet_of(s):
    sys.exit("ip_range %s is not inside subnet %s" % (p, s))
if c in p:
    sys.exit("caddy address %s lies INSIDE ip_range %s: another container could be given it" % (c, p))
print("caddy address %s is in subnet %s and outside ip_range %s" % (c, s, p))
PY
  ); then
    ok "$range_msg"
  else
    fail "compose.yaml: $range_msg"
  fi
else
  warn "no python3: Caddy's address was not checked against ip_range"
fi

# --- STUN list ([stun] urls) and the STUN service (compose.yaml service "stun", config/stun.conf) ---
stun_conf=$ROOT/config/stun.conf
[ -f "$stun_conf" ] || die "missing $stun_conf"
stun_active=$(sed -e 's/[[:space:]]*#.*$//' "$stun_conf")

stun_line=$(sed -n '/^\[stun\]/,/^\[/p' <<<"$active" | grep -E '^urls[[:space:]]*=' || true)
if [ -z "$stun_line" ]; then
  fail "relay.toml: [stun] urls is not set (browsers on other networks get no STUN server from /ice-servers)"
else
  stun_count=0
  while IFS= read -r entry; do
    stun_count=$((stun_count + 1))
    if ! [[ $entry =~ ^stuns?:[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
      fail "relay.toml: [stun] url '$entry' is not stun:host:port (only stun:/stuns:, no credentials, path or query)"
    fi
  done < <(grep -o '"[^"]*"' <<<"$stun_line" | tr -d '"')
  if [ "$stun_count" -eq 0 ]; then
    fail "relay.toml: [stun] urls is empty"
  elif [ "$stun_count" -gt 4 ]; then
    fail "relay.toml: [stun] has $stun_count urls (the server accepts at most 4)"
  else
    ok "[stun] urls: $(grep -o '"[^"]*"' <<<"$stun_line" | tr '\n' ' ')"
  fi
  # The first URL should point at this relay's name and the published STUN port.
  first=$(grep -o '"[^"]*"' <<<"$stun_line" | tr -d '"' | head -n 1)
  want_host=$(env_get RELAY_DOMAIN)
  [ -n "$want_host" ] || want_host=relay.cometcast.de
  want_port=$(env_get STUN_PORT)
  [ -n "$want_port" ] || want_port=3478
  if [ "$first" != "stun:$want_host:$want_port" ]; then
    warn "first [stun] url is '$first', the stun service is published as stun:$want_host:$want_port (RELAY_DOMAIN, STUN_PORT in .env); fine only if that is intended (another STUN host or a NAT port mapping)"
  fi
fi

# The service must exist, publish UDP only, and the coturn config must keep it STUN-only.
if grep -Eq '^  stun:[[:space:]]*$' "$compose_file"; then
  ok "compose.yaml has the stun service"
  stun_ports=$(awk '/^  stun:[[:space:]]*$/ { in_s = 1; next } in_s && (/^  [a-z_-]+:[[:space:]]*$/ || /^[a-z]/) { in_s = 0 } in_s && /^[[:space:]]+- "/ { print $2 }' "$compose_file")
  if [ -n "$stun_ports" ] && ! grep -qv '/udp"$' <<<"$stun_ports"; then
    ok "the stun service publishes UDP only"
  else
    fail "compose.yaml: the stun service must publish only UDP ports (found: ${stun_ports:-none})"
  fi
else
  fail "compose.yaml: no stun service (the [stun] list would point at nothing)"
fi
if grep -Eq '^stun-only[[:space:]]*$' <<<"$stun_active"; then
  ok "stun.conf: stun-only"
else
  fail "config/stun.conf: 'stun-only' is missing (the service could then hand out TURN relays)"
fi
for forbidden in 'no-auth' 'lt-cred-mech' 'use-auth-secret' 'static-auth-secret' 'user' 'userdb' 'cli-password' 'allow-loopback-peers' 'allowed-peer-ip' 'external-ip' 'relay-ip' 'listening-ip' 'tls-listening-port'; do
  if grep -Eq "^$forbidden([[:space:]]*=|[[:space:]]*\$)" <<<"$stun_active"; then
    fail "config/stun.conf: '$forbidden' has no place in a STUN-only service (accounts, secrets, TURN or address settings)"
  fi
done
if grep -Eq '^(no-tcp|no-tls)[[:space:]]*$' <<<"$stun_active" && [ "$(grep -Ec '^(no-tcp|no-tls)[[:space:]]*$' <<<"$stun_active")" -eq 2 ]; then
  ok "stun.conf: UDP only (no-tcp, no-tls)"
else
  fail "config/stun.conf: 'no-tcp' and 'no-tls' must both be set (UDP 3478 only)"
fi

if [ "$N_FAIL" -gt 0 ]; then
  die "$N_FAIL configuration check(s) failed"
fi
