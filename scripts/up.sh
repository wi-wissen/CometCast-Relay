#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Starts (or brings up to date) the relay stack after checking the prerequisites. Does not change
# the version: that is update.sh. Run from any folder as a user who may use docker (not root: the
# secret is only checked for existence, see gen-secrets.sh).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need_cmd docker
[ -f "$ROOT/.env" ] || die "missing .env (cp .env.example .env and edit it)"
state_lock
[ -f "$ROOT/secrets/altcha_secret" ] || die "missing secrets/altcha_secret (sudo scripts/gen-secrets.sh; if it exists, secrets/ must be traversable: root:root 0711, re-run gen-secrets.sh)"

version=$(env_get COMETCAST_VERSION)
is_version "$version" || die "COMETCAST_VERSION in .env must be an exact version such as 0.1.0 (got '$version')"
require_min_version "$version" "COMETCAST_VERSION"

"$ROOT/scripts/lint-config.sh"
compose config -q
# A syntax error in config/caddy.d/*.caddy (your block list) or the Caddyfile would stop Caddy at start:
# find it now, with the pinned image, before anything is restarted.
"$ROOT/scripts/check-caddyfile.sh" --validate-only || die "the Caddyfile or a file in config/caddy.d/ is invalid (see above); nothing was started"

# Pin the image digest under this version (lock file .state/image-lock, COMETCAST_IMAGE_DIGEST in .env), the
# first time only: pull before starting so that the container is created with the digest right away.
image=$IMAGE_REPO:$version
if [ -z "$(lock_digest "$version")" ]; then
  # COMETCAST_VERSION may have been edited by hand: drop a digest left over from the old version first, or
  # the pull would fetch that old digest instead of the tag.
  pin_version "$version"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    info "pulling $image ..."
    compose pull cometcast-server || die "could not pull $image"
  fi
  digest=$(image_digest "$image") || die "$image is not on this host after the pull; cannot record its digest"
  if [ -n "$digest" ]; then
    lock_record "$version" "$digest"
    info "recorded $version = $digest in .state/image-lock"
  else
    warn "$image has no registry digest (a local build): not pinned"
  fi
fi
pin_version "$version"

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
