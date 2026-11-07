#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Validates the Caddyfile and everything it imports (config/caddy.d/*.caddy, for example your block
# list) with the same Caddy image that compose.yaml uses. Needs Docker.
#   scripts/check-caddyfile.sh                 validate and check the format (CI, before changing the proxy configuration)
#   scripts/check-caddyfile.sh --validate-only validate only (up.sh and reload-caddy.sh: a syntax error in the block
#                                              list must be found BEFORE Caddy is restarted, a restart with a broken
#                                              configuration leaves the relay down)
# The domain is RELAY_DOMAIN from .env, else relay.example.org.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_cmd docker

validate_only=0
case "${1:-}" in
  '') ;;
  --validate-only) validate_only=1 ;;
  -h | --help)
    sed -n '2,9p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

image=$(awk '/image: &caddy_image/ { print $3; exit }' "$ROOT/compose.yaml")
[ -n "$image" ] || die "cannot find the Caddy image in compose.yaml"
domain=$(env_get RELAY_DOMAIN)
[ -n "$domain" ] || domain=relay.example.org

run=(docker run --rm
  -e "RELAY_DOMAIN=$domain"
  -v "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro"
  -v "$ROOT/config/caddy.d:/etc/caddy/conf.d:ro"
  "$image")

"${run[@]}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
[ "$validate_only" -eq 0 ] || exit 0
if "${run[@]}" caddy fmt --config /etc/caddy/Caddyfile 2>/dev/null | diff -u "$ROOT/Caddyfile" - >/dev/null; then
  info "Caddyfile is formatted"
else
  die "Caddyfile is not formatted; run: docker run --rm -v \"\$PWD:/w\" $image caddy fmt --overwrite /w/Caddyfile"
fi
