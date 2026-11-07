# Contributing

Changes to scripts, configuration and documentation are welcome. Contributions follow the CLA of the main repository
([CLA.md](https://github.com/wi-wissen/CometCast/blob/main/CLA.md)); the licence is GPL-3.0-or-later.

Before opening a pull request run what CI runs:

```sh
shellcheck -x -P SCRIPTDIR scripts/*.sh firewall/*.sh
scripts/test-lib.sh
python3 -I -m py_compile scripts/ws-check.py scripts/stun-check.py
firewall/gen-nftables.sh --out-dir /tmp/nft --check   # as root: nft -c on the generated files
pip install --require-hashes -r requirements-ci.txt && yamllint -c .yamllint.yaml compose.yaml internal/compose.yaml .github/workflows .yamllint.yaml
scripts/check-stun.sh                      # needs Docker
scripts/lint-config.sh
scripts/check-caddyfile.sh                 # needs Docker
docker compose config --quiet              # with a .env (cp .env.example .env) and secrets/altcha_secret present
sh internal/coturn/test-render.sh
```

Rules that keep the repository safe to copy:

- Bash with `set -euo pipefail`, shellcheck-clean, no `curl | sh`, nothing destructive in `bootstrap.sh`.
- Pin container images by tag and digest and GitHub Actions by full commit SHA (verify with `git ls-remote`).
- Do not edit `internal/coturn/*` or `internal/upstream/*` by hand: they are copies from the product repository, refreshed by
  `scripts/sync-from-product.sh`.
- Mark what you did not test as **UNCERTAIN** in the docs; do not claim more than was run.
