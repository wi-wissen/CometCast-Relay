#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: scripts/rollback.sh [VERSION]
# Goes back to VERSION, or to the most recent earlier version recorded in .state/version-history
# (written by up.sh and update.sh). Pulls the image only if it is not on this host any more.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case "${1:-}" in
  -h | --help)
    sed -n '2,5p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

need_cmd docker
# Extra arguments for verify.sh (only for non-default setups, for example VERIFY_ARGS="--cacert /path/ca.pem").
read -r -a vargs <<<"${VERIFY_ARGS:-}"
[ -f "$ROOT/.env" ] || die "missing .env"
current=$(env_get COMETCAST_VERSION)
target=${1:-}
if [ -z "$target" ]; then
  target=$(previous_version "$current")
  [ -n "$target" ] || die "no earlier version recorded; give one: scripts/rollback.sh VERSION"
fi
is_version "$target" || die "'$target' is not an exact version"
[ "$target" != "$current" ] || die "already on $target"

image=$IMAGE_REPO:$target
if ! docker image inspect "$image" >/dev/null 2>&1; then
  info "$image is not on this host, pulling ..."
  docker pull "$image" || die "cannot get $image; still on $current"
fi

env_set COMETCAST_VERSION "$target"
info "rolling back $current -> $target ..."
if ! wait_healthy 120; then
  compose ps || true
  die "stack not healthy on $target; look at: docker compose logs --tail 100"
fi
record_version "$target"
info "now on $target"
"$ROOT/scripts/verify.sh" --quiet-header "${vargs[@]}"
