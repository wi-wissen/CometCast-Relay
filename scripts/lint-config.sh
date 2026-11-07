#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Static consistency checks of the configuration files (no Docker, no network). Used by up.sh and CI.
# It cannot replace the server's own validation at start; it catches the mistakes that would
# otherwise show up as an outage: wrong mode, TURN section, missing origins, proxy address mismatch.
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

# Lines without comments, for the greps below.
active=$(sed -e 's/[[:space:]]*#.*$//' "$toml")

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
if [ -n "$subnet" ] && [ -n "$caddy_ip" ] && [ "${caddy_ip%.*}" != "${subnet%.*}" ]; then
  fail "compose.yaml: caddy address $caddy_ip is not in subnet $subnet"
fi

if [ "$N_FAIL" -gt 0 ]; then
  die "$N_FAIL configuration check(s) failed"
fi
