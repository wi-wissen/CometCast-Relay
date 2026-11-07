#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Creates secrets/altcha_secret (the key that signs ALTCHA puzzles). Never prints the secret and
# never overwrites an existing one (use --rotate to replace it on purpose: puzzles in flight stop
# working, nothing else happens). The files are not committed (.gitignore).
#
# The server container runs as UID 65532 and reads the file through a bind mount, so the file must
# be readable for that user: owner root, group 65532, mode 0440. That needs root (run with sudo).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

rotate=0
case "${1:-}" in
  '') ;;
  --rotate) rotate=1 ;;
  -h | --help)
    sed -n '2,9p' "${BASH_SOURCE[0]}"
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
  chmod 750 "$dir"
  tmp=$(mktemp "$dir/.altcha_secret.XXXXXX")
  openssl rand -hex 32 >"$tmp"
  mv "$tmp" "$file"
  info "wrote secrets/altcha_secret (64 hex characters)"
fi

chown 0:65532 "$file"
chmod 0440 "$file"

len=$(wc -c <"$file" | tr -d ' ')
[ "$len" -ge 17 ] || die "secrets/altcha_secret is too short ($len bytes); the server needs at least 16 characters"
info "secrets/altcha_secret: owner root:65532, mode 0440, $((len - 1)) characters"
