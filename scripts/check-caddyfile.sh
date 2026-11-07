#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Validates the Caddyfile with the same Caddy image that compose.yaml uses (format and syntax).
# Needs Docker. Used by CI and by hand before changing the proxy configuration.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_cmd docker

image=$(awk '/image: &caddy_image/ { print $3; exit }' "$ROOT/compose.yaml")
[ -n "$image" ] || die "cannot find the Caddy image in compose.yaml"

run=(docker run --rm
  -e RELAY_DOMAIN=relay.example.org
  -v "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro"
  -v "$ROOT/config/caddy.d:/etc/caddy/conf.d:ro"
  "$image")

"${run[@]}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
if "${run[@]}" caddy fmt --config /etc/caddy/Caddyfile 2>/dev/null | diff -u "$ROOT/Caddyfile" - >/dev/null; then
  info "Caddyfile is formatted"
else
  die "Caddyfile is not formatted; run: docker run --rm -v \"\$PWD:/w\" $image caddy fmt --overwrite /w/Caddyfile"
fi
