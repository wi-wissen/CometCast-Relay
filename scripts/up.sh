#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Starts (or brings up to date) the relay stack after checking the prerequisites. Does not change
# the version: that is update.sh. Run from any folder as a user who may use docker.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need_cmd docker
[ -f "$ROOT/.env" ] || die "missing .env (cp .env.example .env and edit it)"
[ -f "$ROOT/secrets/altcha_secret" ] || die "missing secrets/altcha_secret (sudo scripts/gen-secrets.sh)"

version=$(env_get COMETCAST_VERSION)
is_version "$version" || die "COMETCAST_VERSION in .env must be an exact version such as 0.1.0 (got '$version')"

"$ROOT/scripts/lint-config.sh"
compose config -q

info "starting version $version (images are pulled when missing) ..."
if ! wait_healthy 120; then
  compose ps || true
  die "the stack did not become healthy; look at: docker compose logs --tail 100"
fi

if [ ! -f "$HISTORY" ] || [ "$(awk 'END { print $2 }' "$HISTORY")" != "$version" ]; then
  record_version "$version"
fi

compose ps
info "up. Next: scripts/verify.sh"
