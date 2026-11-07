#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: scripts/update.sh [--no-pull] [--no-rollback] VERSION
# Moves the relay to the exact release VERSION (for example 0.1.1; never "latest").
# 1. refuses a VERSION older than MIN_SERVER_VERSION (that is a rollback below what config/relay.toml needs)
# 2. pulls ghcr.io/wi-wissen/cometcast-server:VERSION first; if that fails nothing has changed. The digest of
#    the pulled image is written to .state/image-lock and COMETCAST_IMAGE_DIGEST in .env (what runs is that digest)
# 3. writes the version to .env and recreates the containers (all rooms end; clients reconnect)
# 4. checks the CORE of the relay: cometcast-server and caddy healthy, then scripts/verify.sh --only core
#    (TLS, /healthz, ALTCHA, CORS, the WebSocket handshake, ...). A failure there goes back to the previous
#    version (unless --no-rollback).
# 5. checks the STUN service separately (verify.sh --only stun: UDP, the /ice-servers list). A failure there only
#    prints a warning and KEEPS the new version: the STUN service does not depend on the server version, and a
#    broken UDP path (provider firewall, NAT hairpin) is no reason to take the relay back.
# The checks connect to 127.0.0.1 (the published ports) so that a host that cannot reach its own public address
# (no NAT hairpin) is not mistaken for a broken relay.
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
      sed -n '2,18p' "${BASH_SOURCE[0]}"
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
require_min_version "$version" "update target"

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
digest=$(image_digest "$image")
if [ -n "$digest" ]; then
  info "image: $image ($digest)"
  lock_record "$version" "$digest"
else
  info "image: $image (no registry digest: a local image, not pinned)"
  lock_record "$version" ""
fi
[ -f "$HISTORY" ] || record_version "$current"
# Make sure the version we leave has its digest on record too (for the way back).
if [ -z "$(lock_digest "$current")" ]; then
  cur_digest=$(image_digest "$IMAGE_REPO:$current" || true)
  [ -z "$cur_digest" ] || lock_record "$current" "$cur_digest"
fi
pin_version "$version"
info "updating $current -> $version (rooms end, clients reconnect) ..."

# verify.sh talks to the published ports on this host directly.
core_args=(--quiet-header --ip 127.0.0.1 "${vargs[@]}")

core_ok=1
if ! wait_healthy 120 cometcast-server caddy; then
  fail "cometcast-server or caddy not healthy after the update"
  core_ok=0
else
  rc=0
  "$ROOT/scripts/verify.sh" --only core "${core_args[@]}" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "verify.sh --only core failed after the update (exit code $rc)"
    core_ok=0
  fi
fi

if [ "$core_ok" -eq 1 ]; then
  record_version "$version"
  info "now on $version. Previous version for rollback: $current"
  # The STUN service and its checks: warnings only.
  stun_rc=0
  compose up -d stun >/dev/null 2>&1 || stun_rc=1
  if [ "$stun_rc" -eq 0 ]; then
    "$ROOT/scripts/verify.sh" --only stun "${core_args[@]}" || stun_rc=$?
  fi
  if [ "$stun_rc" -ne 0 ]; then
    warn "the STUN checks failed after the update; the new version $version stays. The relay itself works; browsers on other networks may find no direct path until STUN works again (docker compose logs stun; scripts/verify.sh --only stun; docs/SETUP.md 11)"
  fi
  exit 0
fi

if [ "$rollback" -eq 1 ]; then
  info "going back to $current ..."
  "$ROOT/scripts/rollback.sh" "$current" || die "update to $version failed AND the rollback to $current failed too (see above); the relay may be down: docker compose ps, docker compose logs"
  die "update to $version failed (core check, see above); rolled back to $current, which is running again"
fi
die "update to $version failed and --no-rollback was given; run scripts/rollback.sh when ready"
