# Optional profile: internal server with TURN

**This is not the public relay.** The public relay (`relay.cometcast.de`, repository root) runs in
`open` mode, which has no TURN: the server refuses a `[turn]` section there (it only lists a STUN server, see
[docs/SETUP.md](../docs/SETUP.md) "STUN service"). TURN credentials exist in `internal` mode only; this profile's
coturn also answers STUN on 3478 (`stun_urls` in `[turn]`), so it needs no separate STUN service (do not run it on the same host as the public relay's STUN service: both
want UDP 3478). This folder is for an organisation that wants its own server for its own devices
with a TURN relay (coturn) so calls also work across networks.

Reference for everything below: the product repository,
[deploy/README.md](https://github.com/wi-wissen/CometCast/blob/main/deploy/README.md) and
[docs/server.md](https://github.com/wi-wissen/CometCast/blob/main/docs/server.md).

## What is in here

| Path | Origin |
| --- | --- |
| `coturn/render.sh`, `coturn/test-render.sh`, `coturn/turnserver.conf.template` | **Vendored verbatim** from the product repository. Do not edit; run `scripts/sync-from-product.sh`. |
| `upstream/*` | Reference copies of the product's compose file, example config and `.env.example`. Not used by anything; they exist so `sync-from-product.sh` shows drift. |
| `PRODUCT_COMMIT` | Commit of the product repository the vendored files come from, with SHA-256 of each file (CI checks them). |
| `compose.yaml`, `config/server.example.toml`, `.env.example` | **Derived by hand** from the `upstream/` copies: image by exact version from ghcr.io instead of a local build, own paths. When `upstream/` changes, update these. |

## Setup (internal host with a public or private address)

Run everything in this folder (`internal/`) on a Linux host. Needs Docker with the Compose plugin and a
certificate and key for the server's name (the server reads them from files and must be restarted after a
renewal; or remove `[tls]` and put your own reverse proxy in front, then set `network.trusted_proxies`).

```sh
cp .env.example .env                                  # edit: version, realm, IPs, relay ports
cp config/server.example.toml config/server.toml      # edit: network.allow, turn urls, origins

mkdir -p secrets certs
openssl rand -hex 32 > secrets/turn_secret
openssl rand -hex 32 > secrets/altcha_secret
sudo chown root:65532 secrets/*; sudo chmod 640 secrets/*

cp /path/to/fullchain.pem certs/fullchain.pem
cp /path/to/privkey.pem certs/privkey.pem
sudo chown 65532:65534 certs/privkey.pem; sudo chmod 640 certs/privkey.pem   # server (65532) and coturn (65534) read it

sudo TURN_CONF_GROUP=65534 ./coturn/render.sh         # writes coturn/turnserver.conf (holds the TURN secret)
docker compose up -d
docker compose ps                                     # both services healthy
curl --cacert certs/fullchain.pem https://your.host:8443/healthz
```

`secrets/`, `certs/`, `.env`, `config/server.toml` and `coturn/turnserver.conf` are ignored by git. Never
commit them.

Firewall: TCP 8443 (or 443 behind your proxy), UDP and TCP 3478, TCP 5349, and the UDP relay range from
`.env` (default 49160-49660). Keep coturn's CLI port 5766 closed (it is off). Docker-published ports are
not filtered by ufw rules; coturn uses host networking, so ufw does apply to it.

## Know before you use it

- `render.sh` checks the syntax of `TURN_EXTERNAL_IP`, not whether it is really public.
- With host networking a client holding TURN credentials can send UDP to UDP services on the relay address.
  Use a relay address without other UDP services or firewall them.
- A reverse proxy without `trusted_proxies` makes every client look like one address (one TURN user name and
  quota: error 486 for everybody).
- Run only coturn 4.18.0 (the tag that was tested).

## Status (UNCERTAIN)

`docker compose config` and `coturn/test-render.sh` (164 checks) pass in CI, and the server image started
with a configuration derived from `config/server.example.toml`. This compose file itself was not run with
coturn on a real network. Not verified anywhere: two real devices through TURN, NAT, TURN over TLS (5349),
IPv6, a real certificate, arm64. Read "What is NOT verified" in the product's
[deploy/README.md](https://github.com/wi-wissen/CometCast/blob/main/deploy/README.md#what-is-not-verified-uncertain).

## Refreshing the vendored files

```sh
scripts/sync-from-product.sh                 # from github.com/wi-wissen/CometCast, branch main
scripts/sync-from-product.sh --repo ../CometCast --ref <commit>   # or from a local clone
sh internal/coturn/test-render.sh            # must report 0 failed
```

The script writes the files and the new `PRODUCT_COMMIT`, then shows `git diff`. It does not commit. Read the
diff of `internal/upstream/*` and update `compose.yaml` and `config/server.example.toml` where needed.
