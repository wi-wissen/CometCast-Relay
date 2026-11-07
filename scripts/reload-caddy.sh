#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Applies a changed Caddyfile or block list (config/caddy.d/blocklist.caddy) without a restart and without
# losing a room: validates first, then asks the running Caddy to reload. If the configuration is invalid
# nothing is touched and Caddy keeps running with the old one. (`docker compose restart caddy` with an invalid
# file would leave the relay down, so use this script, not a restart, for block list changes.)
# Usage: scripts/reload-caddy.sh
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_cmd docker
[ -f "$ROOT/.env" ] || die "missing .env"

"$ROOT/scripts/check-caddyfile.sh" --validate-only || die "the configuration is invalid; Caddy was NOT reloaded (still running the old one)"
compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
info "Caddy reloaded"
