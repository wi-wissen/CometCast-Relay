#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Refreshes the vendored copies in internal/ from the product repository (wi-wissen/CometCast) and
# shows what changed. It does NOT commit; review the diff, run internal/coturn/test-render.sh, commit.
#
# Usage: scripts/sync-from-product.sh [--repo PATH_OR_URL] [--ref REF]
#   --repo  a local clone, or a git URL (default: https://github.com/wi-wissen/CometCast)
#   --ref   branch, tag or commit to take (default: main). A URL is cloned shallow into a temporary folder.
#
# Vendored verbatim (used):          internal/coturn/{render.sh,test-render.sh,turnserver.conf.template}
# Reference copies (not used as-is): internal/upstream/{docker-compose.yml,cometcast-server.example.toml,env.example}
#   internal/compose.yaml and internal/config/server.example.toml are DERIVED from those by hand; when the
#   upstream copies change, read the diff and update the derived files.
# Records the commit in internal/PRODUCT_COMMIT.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_cmd git

repo=https://github.com/wi-wissen/CometCast
ref=main
while [ $# -gt 0 ]; do
  case $1 in
    --repo | --ref)
      [ $# -ge 2 ] || die "$1 needs a value"
      if [ "$1" = --repo ]; then repo=$2; else ref=$2; fi
      shift
      ;;
    -h | --help)
      sed -n '2,15p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -d "$repo/.git" ] || [ -f "$repo/.git" ]; then
  src=$repo
  git -C "$src" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || die "ref '$ref' not found in $src"
  commit=$(git -C "$src" rev-parse "$ref^{commit}")
  # Export the committed state of that ref (not the working tree).
  git -C "$src" archive "$commit" deploy | tar -x -C "$work"
  date=$(git -C "$src" show -s --format=%cs "$commit")
else
  git init -q "$work/clone"
  git -C "$work/clone" fetch -q --depth 1 "$repo" "$ref" || die "cannot fetch $ref from $repo"
  commit=$(git -C "$work/clone" rev-parse FETCH_HEAD)
  git -C "$work/clone" archive "$commit" deploy | tar -x -C "$work"
  date=$(git -C "$work/clone" show -s --format=%cs "$commit")
fi

dep=$work/deploy
for f in coturn/render.sh coturn/test-render.sh coturn/turnserver.conf.template docker-compose.yml config/cometcast-server.example.toml .env.example; do
  [ -f "$dep/$f" ] || die "product repository has no deploy/$f at $commit; the layout changed, update this script"
done

dest=$ROOT/internal
mkdir -p "$dest/coturn" "$dest/upstream"
install -m 0755 "$dep/coturn/render.sh" "$dest/coturn/render.sh"
install -m 0755 "$dep/coturn/test-render.sh" "$dest/coturn/test-render.sh"
install -m 0644 "$dep/coturn/turnserver.conf.template" "$dest/coturn/turnserver.conf.template"
install -m 0644 "$dep/docker-compose.yml" "$dest/upstream/docker-compose.yml"
install -m 0644 "$dep/config/cometcast-server.example.toml" "$dest/upstream/cometcast-server.example.toml"
install -m 0644 "$dep/.env.example" "$dest/upstream/env.example"

{
  echo "# Written by scripts/sync-from-product.sh. Do not edit by hand."
  echo "source: https://github.com/wi-wissen/CometCast (path deploy/)"
  echo "commit: $commit"
  echo "commit-date: $date"
  echo "files (sha256 of the vendored copies):"
  (cd "$dest" && sha256sum coturn/render.sh coturn/test-render.sh coturn/turnserver.conf.template upstream/docker-compose.yml upstream/cometcast-server.example.toml upstream/env.example | sed -e 's/^/  /')
} >"$dest/PRODUCT_COMMIT"

info "Synced internal/ from CometCast $commit ($date)."
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  info
  info "Changes against the last commit of this repository:"
  git -C "$ROOT" --no-pager diff --stat -- internal/coturn internal/upstream internal/PRODUCT_COMMIT
  git -C "$ROOT" --no-pager diff -- internal/coturn internal/upstream
  git -C "$ROOT" status --short -- internal | grep '^??' || true
fi
info
info "Next: sh internal/coturn/test-render.sh, read the diff of internal/upstream/* and update internal/compose.yaml and internal/config/server.example.toml if needed, then commit."
