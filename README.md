# cometcast-relay

Operating package for the public Comet Cast relay at **`relay.cometcast.de`**. The same files can run your
own relay: change the domain, the web origin and the version.

> **Status:** the stack (server image, Caddy, scripts, update, rollback) was run once on a local machine with a
> private certificate. It has not run on a real VPS with a public name yet, and `relay.cometcast.de` does not
> exist yet. Everything unverified is marked **UNCERTAIN** in [docs/SETUP.md](docs/SETUP.md).

## Relation to the product repository

| Repository | Holds |
| --- | --- |
| [wi-wissen/CometCast](https://github.com/wi-wissen/CometCast) | The code (`cometcast-server`), the Docker image build (`deploy/Dockerfile`), the server documentation and the generic deployment files. Releases push `ghcr.io/wi-wissen/cometcast-server:<version>`. |
| this repository | How to run that image as a public relay: Compose stack with Caddy (automatic TLS), the relay configuration, firewall files, scripts for setup checks, secrets, start, update, rollback and verification, and the runbook. It does **not** build the image. |

Source of truth for server behaviour and settings: the product repository's `docs/server.md` and
`bins/cometcast-server/README.md`.

## What the relay is

An **open-mode** `cometcast-server` behind Caddy: it mediates connections (room codes, WebRTC offers and answers),
protects room creation with an ALTCHA proof-of-work and stores nothing on disk. The web app is static (GitHub
Pages) and calls the relay over `wss` with CORS (`allowed_origins`). **No TURN and no STUN**: the server refuses
TURN configuration in open mode. For an internal server with coturn see [internal/](internal/README.md).

## Quick start (fresh Debian/Ubuntu VPS with Docker)

```sh
git clone https://github.com/wi-wissen/cometcast-relay /opt/cometcast-relay && cd /opt/cometcast-relay
scripts/bootstrap.sh              # read-only host checks, changes nothing
cp .env.example .env              # set COMETCAST_VERSION (exact release) and RELAY_DOMAIN
sudo scripts/gen-secrets.sh       # secrets/altcha_secret, never committed
scripts/up.sh                     # lint, pull, start, wait until healthy
scripts/verify.sh                 # pass/fail checks: TLS, CORS, ALTCHA, WebSocket
```

The full runbook (DNS, firewall, SSH, Docker, update, rollback, backups, monitoring, abuse handling, compromise):
**[docs/SETUP.md](docs/SETUP.md)**.

## Contents

| Path | Content |
| --- | --- |
| [docs/SETUP.md](docs/SETUP.md) | Step-by-step runbook and operations guide |
| `compose.yaml`, `Caddyfile`, `.env.example` | The stack: server (internal network, read-only, non-root) behind Caddy |
| `config/relay.toml` | Server configuration for `relay.cometcast.de` (no secrets) |
| `config/caddy.d/` | Operator block list for Caddy (`blocklist.caddy`, not committed) |
| `scripts/` | `bootstrap.sh`, `gen-secrets.sh`, `up.sh`, `update.sh VERSION`, `rollback.sh`, `verify.sh` (+ `ws-check.py`), `lint-config.sh`, `check-caddyfile.sh`, `sync-from-product.sh` |
| `firewall/` | `ufw.sh` and `nftables.conf` for the host |
| [internal/](internal/README.md) | Optional internal-mode profile with coturn (vendored from the product repository) |
| `.github/workflows/check.yml` | CI: shellcheck, yamllint, `docker compose config`, Caddyfile validation, config checks |

## Licence

GPL-3.0-or-later, see [LICENSE](LICENSE). Contributions follow the CLA of the main repository
([CLA.md](https://github.com/wi-wissen/CometCast/blob/main/CLA.md)). Security reports: [SECURITY.md](SECURITY.md).
