#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: scripts/rollback.sh [VERSION]
# Goes back to VERSION, or to the most recent earlier version recorded in .state/version-history
# (written by up.sh and update.sh) that is not older than MIN_SERVER_VERSION. Refuses a VERSION below that
# minimum: such a server does not know the [stun] section of config/relay.toml and would not start.
# Pulls the image only if it is not on this host any more; starts the digest recorded in
# .state/image-lock when there is one. Then checks the core with scripts/verify.sh --only core (the same
# checks as update.sh; a failing STUN check only warns).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case "${1:-}" in
  -h | --help)
    sed -n '2,9p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

need_cmd docker
# Extra arguments for verify.sh (only for non-default setups, for example VERIFY_ARGS="--cacert /path/ca.pem").
read -r -a vargs <<<"${VERIFY_ARGS:-}"
[ -f "$ROOT/.env" ] || die "missing .env"
state_lock
current=$(env_get COMETCAST_VERSION)
target=${1:-}
min=$(min_server_version)
if [ -z "$target" ]; then
  # Newest earlier version of the history that is allowed.
  if [ -f "$HISTORY" ]; then
    while read -r _ v; do
      if [ -z "$v" ] || [ "$v" = "$current" ] || ! is_version "$v"; then continue; fi
      if [ -n "$min" ] && version_lt "$v" "$min"; then continue; fi
      target=$v
    done <"$HISTORY"
  fi
  if [ -z "$target" ]; then
    if [ -n "$(previous_version "$current")" ]; then
      die "no earlier version at or above the minimum server version ${min:-none} is recorded (the recorded ones are older); give one: scripts/rollback.sh VERSION"
    fi
    die "no earlier version recorded; give one: scripts/rollback.sh VERSION"
  fi
fi
is_version "$target" || die "'$target' is not an exact version"
[ "$target" != "$current" ] || die "already on $target"
require_min_version "$target" "rollback target"

image=$IMAGE_REPO:$target
if ! docker image inspect "$image" >/dev/null 2>&1; then
  info "$image is not on this host, pulling ..."
  # The recorded digest (if any) is what we want, not whatever the tag points to today.
  want=$(lock_digest "$target")
  if [ -n "$want" ]; then
    docker pull "$IMAGE_REPO@$want" || die "cannot get $IMAGE_REPO@$want; still on $current"
    docker tag "$IMAGE_REPO@$want" "$image"
  else
    docker pull "$image" || die "cannot get $image; still on $current"
  fi
fi

pin_version "$target"
info "rolling back $current -> $target ..."
if ! wait_healthy 120 cometcast-server caddy; then
  compose ps || true
  die "cometcast-server or caddy not healthy on $target; look at: docker compose logs --tail 100"
fi
record_version "$target"
info "now on $target"
ip=$(check_ip)
rc=0
"$ROOT/scripts/verify.sh" --only core --quiet-header --ip "$ip" "${vargs[@]}" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
compose up -d stun >/dev/null 2>&1 || true
"$ROOT/scripts/verify.sh" --only stun --quiet-header --ip "$ip" "${vargs[@]}" || warn "the STUN checks failed (the relay itself is fine): docker compose logs stun; scripts/verify.sh --only stun"
