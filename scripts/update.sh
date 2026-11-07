#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: scripts/update.sh [--no-pull] [--no-rollback] VERSION
# Moves the relay to the exact release VERSION (for example 0.1.1; never "latest").
# 1. pulls ghcr.io/wi-wissen/cometcast-server:VERSION first; if that fails nothing has changed
# 2. writes the version to .env and recreates the containers (all rooms end; clients reconnect)
# 3. waits until healthy and runs scripts/verify.sh; on failure goes back to the previous
#    version (unless --no-rollback)
# --no-pull: use an image that is already on this host (for example loaded with `docker load`).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pull=1
rollback=1
version=
while [ $# -gt 0 ]; do
  case $1 in
    --no-pull) pull=0 ;;
    --no-rollback) rollback=0 ;;
    -h | --help)
      sed -n '2,10p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    -*) die "unknown option: $1" ;;
    *)
      [ -z "$version" ] || die "only one VERSION"
      version=$1
      ;;
  esac
  shift
done
[ -n "$version" ] || die "usage: scripts/update.sh [--no-pull] [--no-rollback] VERSION"
is_version "$version" || die "'$version' is not an exact version (MAJOR.MINOR.PATCH[-pre], no 'v', not 'latest')"

need_cmd docker
# Extra arguments for verify.sh (only for non-default setups, for example VERIFY_ARGS="--cacert /path/ca.pem").
read -r -a vargs <<<"${VERIFY_ARGS:-}"
[ -f "$ROOT/.env" ] || die "missing .env"
current=$(env_get COMETCAST_VERSION)
if [ "$current" = "$version" ]; then
  info "already on $version; nothing to do (scripts/up.sh re-applies the configuration)"
  exit 0
fi

image=$IMAGE_REPO:$version
if [ "$pull" -eq 1 ]; then
  info "pulling $image ..."
  docker pull "$image" || die "could not pull $image; nothing was changed (still on $current)"
else
  docker image inspect "$image" >/dev/null 2>&1 || die "$image is not on this host (nothing was changed)"
fi
digest=$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}no registry digest (local image){{end}}' "$image")
info "image: $digest"

[ -f "$HISTORY" ] || record_version "$current"
env_set COMETCAST_VERSION "$version"
info "updating $current -> $version (rooms end, clients reconnect) ..."

good=1
if ! wait_healthy 120; then
  fail "stack not healthy after the update"
  good=0
elif ! "$ROOT/scripts/verify.sh" --quiet-header "${vargs[@]}"; then
  fail "verify.sh failed after the update"
  good=0
fi

if [ "$good" -eq 1 ]; then
  record_version "$version"
  info "now on $version. Previous version for rollback: $current"
  exit 0
fi

if [ "$rollback" -eq 1 ]; then
  info "going back to $current ..."
  exec "$ROOT/scripts/rollback.sh" "$current"
fi
die "update to $version failed and --no-rollback was given; run scripts/rollback.sh when ready"
