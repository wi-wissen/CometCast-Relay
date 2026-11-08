#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Applies a changed Caddyfile or block list (config/caddy.d/blocklist.caddy) without a restart and without
# losing a room: validates first, then asks the running Caddy to reload. If the configuration is invalid
# nothing is touched and Caddy keeps running with the old one. (`docker compose restart caddy` with an invalid
# file would leave the relay down, so use this script, not a restart, for block list changes.)
# The Caddyfile is a single-file bind mount: an editor that replaces the file (new inode) leaves the container with
# the old one. The script compares both copies and, if they differ, does not reload but tells you to recreate Caddy.
# Usage: scripts/reload-caddy.sh
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_cmd docker
[ -f "$ROOT/.env" ] || die "missing .env"

"$ROOT/scripts/check-caddyfile.sh" --validate-only || die "the configuration is invalid; Caddy was NOT reloaded (still running the old one)"
host_sum=$(sha256sum <"$ROOT/Caddyfile" | awk '{ print $1 }')
ctr_sum=$(compose exec -T caddy cat /etc/caddy/Caddyfile | sha256sum | awk '{ print $1 }') || die "cannot read /etc/caddy/Caddyfile in the caddy container (is it running? docker compose ps)"
if [ "$host_sum" != "$ctr_sum" ]; then
  die "the caddy container does not see the current Caddyfile (the file was replaced, so its single-file mount is stale); Caddy was NOT reloaded. The new configuration is valid: apply it with docker compose up -d --force-recreate caddy (open connections end, clients reconnect)"
fi
compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
info "Caddy reloaded"
