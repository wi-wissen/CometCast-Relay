#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Creates secrets/altcha_secret (the key that signs ALTCHA puzzles). Never prints the secret and
# never overwrites an existing one (use --rotate to replace it on purpose). The server reads the secret only
# at start: a rotation takes effect after `docker compose up -d --force-recreate cometcast-server`, which ends
# all rooms (clients reconnect) and makes puzzles in flight fail once. The files are not committed (.gitignore).
#
# The server container runs as UID 65532 and reads the file through a bind mount, so the file must
# be readable for that user: owner root, group 65532, mode 0440. That needs root (run with sudo).
# The directory is root:root, mode 0711: every user may walk through it (so that up.sh, bootstrap.sh and
# `docker compose` run by the unprivileged `deploy` user can see that secrets/altcha_secret exists), but
# only root may list it, and the file itself stays unreadable for everybody else. The Docker daemon (root)
# does the bind mount; the deploy user never needs to read the secret.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

rotate=0
case "${1:-}" in
  '') ;;
  --rotate) rotate=1 ;;
  -h | --help)
    sed -n '2,14p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  die "run as root (sudo $0): the file must be owned by root and readable by group 65532"
fi
need_cmd openssl

dir=$ROOT/secrets
file=$dir/altcha_secret

if [ -e "$file" ] && [ "$rotate" -eq 0 ]; then
  info "secrets/altcha_secret exists, left unchanged (--rotate replaces it)"
else
  umask 077
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.altcha_secret.XXXXXX")
  openssl rand -hex 32 >"$tmp"
  mv "$tmp" "$file"
  info "wrote secrets/altcha_secret (64 hex characters)"
  if [ "$rotate" -eq 1 ]; then
    info "the running server still uses the old secret: apply the new one with docker compose up -d --force-recreate cometcast-server (ends all rooms; clients reconnect)"
  fi
fi

# Always (also when the file exists): fixes directories made by older versions of this script (0750).
chown 0:0 "$dir"
chmod 0711 "$dir"
chown 0:65532 "$file"
chmod 0440 "$file"

len=$(wc -c <"$file" | tr -d ' ')
[ "$len" -ge 17 ] || die "secrets/altcha_secret is too short ($len bytes); the server needs at least 16 characters"
info "secrets/altcha_secret: owner root:65532, mode 0440, $((len - 1)) characters; secrets/ is root:root 0711"
