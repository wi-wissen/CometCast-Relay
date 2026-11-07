# Setting up and running relay.cometcast.de

A step-by-step runbook for one fresh Debian or Ubuntu VPS. Written so that you can also run your own relay
(change the name, the origin and the version).

Status: the whole stack (server image, Caddy, STUN service, scripts, update, rollback) was run **once on a local machine with a
private certificate** (section 12). It has **not** been run on a real VPS with a public name and a Let's Encrypt
certificate. Everything that depends on that is marked **UNCERTAIN**. Do a dry run with a test name first.

## 0. What you are building

```
browser (https://cometcast.de/app/)  --wss/https-->  relay.cometcast.de:443
                                                         |
                                                    Caddy (TLS, automatic certificate)
                                                         |  plain HTTP, internal Docker network
                                                    cometcast-server (open mode, port 8443, not published)

browser / app  --UDP 3478-->  relay.cometcast.de:3478  --> stun (coturn, STUN only: no relaying)
```

- **Open mode:** the server mediates connections (room codes, WebRTC offers and answers). Creating a room needs a solved
  ALTCHA proof-of-work puzzle. Join approval ("who may join") is a feature of the clients, not of the server. The server
  stores nothing on disk and never relays images, files or media.
- **STUN yes, TURN no.** Connection order of the product: direct WebRTC first, then an internal server (TURN/SFU), then
  the receiver's own Wi-Fi. For the direct step across NATs a browser needs a STUN server, so the public relay lists one
  at `GET /ice-servers` (`[stun]` in `config/relay.toml`, answer `[{"urls":["stun:relay.cometcast.de:3478"]}]`, no
  credentials) and runs it itself (service `stun`, section 10.9): coturn in STUN-only mode, no third party. The server
  still refuses a `[turn]` section in open mode: open TURN would be an abuse risk, so relayed media exists on internal
  servers only. Use the optional `internal/` profile for an organisation's own server with TURN; it is a different
  server, not an add-on for the public one. Without TURN, a connection between two devices behind strict NATs or
  firewalls (for example symmetric NAT on both sides) can still fail; the share is unmeasured.
- **Caddy** terminates TLS, gets and renews the certificate itself, passes only `/ws`, `/healthz`, `/altcha/challenge`
  and `/ice-servers` to the server (everything else is 404; the Docker image also contains a copy of the web app, which the public relay
  does not offer) and sets `X-Forwarded-For`. The server believes that header only from Caddy's address
  (`network.trusted_proxies`).
- **CORS:** the web app on GitHub Pages calls the relay from another origin. `allowed_origins = ["https://cometcast.de"]`
  in `config/relay.toml` makes the server answer CORS requests for that origin only and refuse `/ws` upgrades from other
  browser origins. The origin has no path: the web app at `https://cometcast.de/app/` has the origin `https://cometcast.de`.

## 1. Before you start

| Need | Notes |
| --- | --- |
| A VPS | Debian 12/13 or Ubuntu 22.04/24.04, amd64 (arm64: the image supports it in the release plan, but it was never run), a public IPv4 address, 1 vCPU, 1 GiB RAM, 10 GB disk. The limits in `compose.yaml` assume about 1 GiB. **UNCERTAIN: no load was ever measured**, so the size is a guess. |
| A domain name you control | For the public relay: `relay.cometcast.de`. |
| Outbound internet from the VPS | Docker images (Docker Hub for Caddy, ghcr.io for the server), Let's Encrypt. |
| Inbound TCP 80 and 443 | 80 is needed for certificate requests and the HTTP-to-HTTPS redirect. |
| Inbound UDP 3478 | The STUN service (section 10.9). Check the provider's firewall as well: many block UDP by default. |
| An exact release of the server image | It must be a release that **knows the `[stun]` section** (product change "Add STUN support to open mode"); an older server refuses to start (unknown key). **UNCERTAIN: which version number first contains it.** Tags of `ghcr.io/wi-wissen/cometcast-server` (see the product repository's [docs/releasing.md](https://github.com/wi-wissen/CometCast/blob/main/docs/releasing.md)). **UNCERTAIN: no release has been published yet**, so `0.1.0` in `.env.example` is a placeholder. The release workflow pushes only the version tag; `latest` is moved by a separate workflow and is not used here. |

Hosting provider, region and registrar are the owner's choice (section 13). For a German project, a provider in the EU
simplifies the privacy notice; this is a suggestion, not a requirement of the software.

## 2. DNS

At the DNS provider of `cometcast.de` (the web site and web app at `cometcast.de` stay as they are on GitHub Pages; their
records are described in the product repository's [docs/website.md](https://github.com/wi-wissen/CometCast/blob/main/docs/website.md)):

| Name | Type | Value |
| --- | --- | --- |
| `relay.cometcast.de` | A | the VPS's public IPv4 address |
| `relay.cometcast.de` | AAAA | **not yet** (see below) |

The STUN service uses the same name (`stun:relay.cometcast.de:3478`); no extra record is needed. It is published on IPv4
only, like the other ports.

- Use a short TTL (300 s) until everything works, raise it later. Do not use a wildcard record.
- **Do not create an AAAA record yet.** `compose.yaml` publishes the ports on IPv4 only. Docker's IPv6 port publishing
  goes through a userland proxy that, as far as known, replaces the client's address with the bridge address, which would
  put every IPv6 client into one rate-limit bucket. **UNCERTAIN: not tested.** Add IPv6 only after you have tried it
  (publish `[::]:443`, enable ip6tables in Docker, then check in Caddy's access log that real client addresses arrive).
- Optional discovery record (nothing reads it today, client-side discovery is not built):
  `_cometcast._tcp.cometcast.de. 3600 IN SRV 10 0 443 relay.cometcast.de.`
- Check from your laptop: `dig +short relay.cometcast.de A` shows the VPS address.

## 3. Prepare the host

Log in as root on the new VPS (first time only), then:

1. **Updates and unattended security updates**
   ```sh
   apt-get update && apt-get -y upgrade
   apt-get install -y unattended-upgrades ca-certificates curl git openssl python3 iproute2 ufw
   dpkg-reconfigure -plow unattended-upgrades
   ```
2. **A normal user with your SSH key, and key-only SSH**
   ```sh
   adduser --disabled-password --gecos "" deploy
   install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
   # paste your public key into /home/deploy/.ssh/authorized_keys, mode 600, owner deploy
   printf 'PasswordAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/10-relay.conf
   sshd -t && systemctl reload ssh      # keep this session open and log in as deploy in a second window FIRST
   ```
   (On Debian the service is `ssh`; on some systems `sshd`.) Test the key login before closing the root session.
3. **Docker Engine with the Compose plugin.** Follow the official instructions for your system (apt repository method):
   <https://docs.docker.com/engine/install/debian/> or <https://docs.docker.com/engine/install/ubuntu/>. Do not pipe a
   downloaded script into a shell. Then:
   ```sh
   usermod -aG docker deploy      # membership of 'docker' is equivalent to root on this host; only this user
   docker compose version         # needs a version that supports `up --wait` (Compose 2.x; 5.6.1 was used)
   ```
   Log in again so the group applies. `compose.yaml` sets log rotation per service.
4. **Host firewall.** Two ready files, use one of them (read the comments in the file first; keep a second SSH session open):
   ```sh
   firewall/ufw.sh              # prints the commands (dry run)
   sudo firewall/ufw.sh --apply
   # or: sudo nft -c -f firewall/nftables.conf   (check), then sudo nft -f firewall/nftables.conf
   ```
   **Docker and ufw:** ports that Docker publishes (80, 443, UDP 3478) are forwarded before ufw's rules and are not filtered by them.
   The firewall protects the host's own services (SSH). To block a client address for the relay use Caddy's block list
   (section 10.5), not `ufw deny`. A provider-level firewall (security group) in front of the VPS is a good second layer.
   **STUN rate limit:** load `firewall/stun-ratelimit.nft` in addition (`sudo nft -c -f firewall/stun-ratelimit.nft`, then
   `sudo nft -f firewall/stun-ratelimit.nft`; it is its own table and works next to ufw or `nftables.conf`). It is the only
   firewall piece that sees the published UDP port; see section 10.9 for what it does and does not protect.
5. **Time:** `timedatectl` must show `System clock synchronized: yes` (TLS and ALTCHA expiry depend on it).

## 4. Get this repository

As user `deploy`:

```sh
sudo install -d -o deploy -g deploy /opt/cometcast-relay
git clone https://github.com/wi-wissen/cometcast-relay /opt/cometcast-relay
cd /opt/cometcast-relay
scripts/bootstrap.sh              # read-only checks: OS, Docker, ports, DNS, firewall, clock
```

`bootstrap.sh` changes nothing. It prints `ok`, `warn` and `FAIL` lines and exits 1 on a FAIL. Fix every FAIL
(typically Docker or DNS) and re-run. Warnings are advice (for example "no firewall found" before step 3.4).

## 5. Configure

```sh
cp .env.example .env
$EDITOR .env
```

| Key in `.env` | Meaning |
| --- | --- |
| `COMETCAST_VERSION` | Exact server release, for example `0.1.0`. Never `latest`. |
| `RELAY_DOMAIN` | `relay.cometcast.de` (the name Caddy requests the certificate for). |
| `BIND_ADDR`, `HTTP_PORT`, `HTTPS_PORT`, `STUN_PORT` | Leave commented on a real server (defaults `0.0.0.0`, 80, 443, UDP 3478). `STUN_PORT` is the host side of the STUN port; if you change it, change the URL in `[stun]` too. |

`config/relay.toml` is committed with the real values for `relay.cometcast.de` (no secrets). For your own relay edit:

- `allowed_origins`: the origins of **your** web app (`https://host[:port]`, exact, no path, no `*`).
- `[stun] urls`: the relay's own name and the STUN port (`stun:relay.cometcast.de:3478`); at most 4, only `stun:`/`stuns:`,
  no credentials. Use your own name for your own relay.
- `network.trusted_proxies`: must equal Caddy's address in `compose.yaml` (`172.29.53.2/32`). If you change the subnet
  there, change it here too. `scripts/lint-config.sh` checks the pair and the other invariants (open mode, no `[turn]`,
  no inline secret, origins well-formed, `[stun]` urls well-formed, the stun service exists, publishes UDP only and its
  coturn config is STUN-only). It runs automatically in `up.sh` and in CI.
- Leave all `limits.*` unset: open mode has strict defaults and all numbers are unmeasured placeholders in the product.
  Do not lower them without measuring. Shared networks (a school, an office behind one address) share one bucket per
  address, see section 11.

A change of `relay.toml` needs `docker compose restart cometcast-server` (all rooms end).

## 6. Secrets

```sh
sudo scripts/gen-secrets.sh
```

Creates `secrets/altcha_secret` (64 hex characters from `openssl rand`), owner `root`, group `65532` (the user of the server
image), mode `0440`. It never prints the secret, never overwrites an existing one (`--rotate` replaces it: puzzles in
flight stop working, nothing else) and the directory is ignored by git. The server needs the secret file so that
puzzles survive a restart. There is no other secret in this stack: Caddy's certificates are created by Caddy itself on the
first start and live in a Docker volume.

## 7. First start

```sh
scripts/up.sh
```

`up.sh` checks `.env` and the secret, runs `lint-config.sh` and `docker compose config`, then
`docker compose up -d --wait` (pulls the images, waits until both containers are healthy) and records the version in
`.state/version-history` (used by the rollback script). On the first start Caddy requests the certificate; this takes
seconds when DNS and ports are right.

```sh
docker compose ps                                   # cometcast-server and caddy: healthy
docker compose logs --no-log-prefix caddy | grep -iE 'obtained|certificate|error' | tail
```

A success line says `certificate obtained successfully`. If it does not appear: DNS not yet propagated, port 80/443
blocked (provider firewall), or Let's Encrypt rate limits (section 11). Caddy retries by itself with a backoff.
**UNCERTAIN: the real Let's Encrypt issuance was not run.**

## 8. Verify

```sh
scripts/verify.sh
```

Pass/fail output, exit code 0 only if everything passed. It checks, in this order: both containers healthy; the TLS
certificate verifies and is valid for at least 14 more days; `GET /healthz` is `200 ok`; port 80 redirects to HTTPS;
`/` is `404`; `GET /ice-servers` is `200` with a STUN-only list (entries have only `urls`, they equal `[stun] urls` in
`config/relay.toml`) and the CORS and `no-store` headers; a real STUN Binding request over UDP to the host and port of the
first URL (`scripts/stun-check.py`) gets a success with your public address and a small answer (at most 3 times the request),
a TURN Allocate request gets no success, and random bytes get no answer; `GET /altcha/challenge` returns a puzzle with `Cache-Control: no-store` and
`Access-Control-Allow-Origin: https://cometcast.de`; the CORS preflight from `https://cometcast.de` gives `204` and from a
foreign origin `403`; a real WebSocket handshake (`scripts/ws-check.py`, standard library only) from the allowed origin
gives `101`, a `hello` answer, and `altcha_required` for `create_room` without a puzzle solution (proves open mode with
proof-of-work), from a foreign origin `403`, and without an `Origin` header (native clients) `101`.

The same checks by hand, for understanding or from another machine:

```sh
R=relay.cometcast.de; O=https://cometcast.de
curl -sS https://$R/healthz                                         # ok
curl -sS -D- -o /dev/null -H "Origin: $O" https://$R/altcha/challenge | grep -iE '^(HTTP|access-control|cache-control)'
curl -sS -D- -o /dev/null -X OPTIONS -H "Origin: $O" -H 'Access-Control-Request-Method: GET' https://$R/altcha/challenge   # 204
curl -sS -D- -o /dev/null -X OPTIONS -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: GET' https://$R/altcha/challenge  # 403
python3 -I scripts/ws-check.py --host $R --origin $O                # ok: 101, hello answered, ... altcha_required
python3 -I scripts/ws-check.py --host $R --origin https://evil.example --mode reject    # ok: handshake refused with 403
```

From another machine (no Docker needed; clone this repository there, `curl`, `openssl` and `python3` are enough):
`scripts/verify.sh --no-compose --origin https://cometcast.de` (add `--no-udp` from a network that blocks UDP). Running
it from **outside** is the only way to see the real STUN answer: the address in the answer must be the machine's public
address, not a `172.x` one.
Before DNS is switched, `--ip ADDRESS` connects to a given address (the certificate then does not verify unless the name
points there; use it only after the A record exists).

**The one thing the script cannot prove: the client address.** Open the web app from your own machine and check what
Caddy sees. Temporarily enable the access log (section 10.5), call `https://relay.cometcast.de/healthz` from your laptop and
check that `client_ip` in the log is **your** address, not a `172.x` Docker address. If it is a Docker address, every
client shares one bucket and the relay will look like an outage under load. **UNCERTAIN: not tested on a real host** (the
local test showed the Docker gateway address for a request from the same machine, which is expected there).

## 9. Connect the web app

The web app is static and lives on GitHub Pages. It picks its relay in this order: `?server=` in the URL, an optional
`config.json` next to `index.html`, the build-time `VITE_DEFAULT_RELAY`, then its own origin. The Pages workflow of the product
repository builds with `VITE_DEFAULT_RELAY=wss://relay.cometcast.de/ws`, so no change is needed here. For a quick test of a
relay: `https://cometcast.de/app/?server=wss://relay.cometcast.de/ws`. Then create a room in one browser and join with the code
in another (two real browsers, ideally on different networks). **UNCERTAIN: real GitHub Pages (path `/app/`, optional
`config.json` 404) and the whole flow against the real relay were not tried.** The web app asks only `/ice-servers`, so
it takes the relay's STUN server from there; direct connections across networks work where NATs allow them, and
without TURN not everywhere (section 0). **UNCERTAIN: a real browser connection across two networks through this STUN
service was never made.**

## 10. Operate

### 10.1 Logs

```sh
docker compose ps
docker compose logs --tail 100                    # both services
docker compose logs -f --since 10m cometcast-server
docker compose logs --no-log-prefix caddy | jq -r 'select(.level=="error" or .level=="warn") | .msg'   # needs jq
```

- **Server:** prints a start banner (version, mode, ALTCHA, allowed origins, trusted proxy) and warnings. It has **no log
  levels, no access log, no metrics endpoint** and does not log bans or rate limits. Expected banner lines:
  `mode: open (mediation only); ALTCHA for create_room: required`, `STUN list: on (GET /ice-servers, no credentials)`, `allowed web origins: https://cometcast.de ...`,
  `trusting X-Forwarded-For from 1 proxy network(s)`.
- **Caddy:** container log with errors and certificate events. The access log is off (it records IP addresses; section 10.5).
- **STUN (coturn):** `docker compose logs stun` shows the start-up lines only. At the default verbosity coturn does **not** log STUN Binding requests or client addresses (checked: no line per request). Keep it that way: do not add `verbose` to `config/stun.conf` without deciding about the privacy notice.
- Logs rotate per service: `json-file`, 10 MB x 5 files each. Look at them with `docker compose logs`, they live under
  `/var/lib/docker/containers/`.

### 10.2 Restart, stop, configuration change

```sh
docker compose restart stun               # config/stun.conf changed (the file is read at start)
docker compose restart cometcast-server   # config/relay.toml changed; ends all rooms; also clears all bans (see 10.5)
docker compose restart caddy              # Caddyfile changed (single-file mount: an editor that replaces the file needs this)
docker compose up -d --force-recreate     # everything
docker compose down                        # stop (volumes, and so the certificates, stay)
```

### 10.3 Update to a new version

Read the release notes of the product repository first. Pull and start an **exact** tag:

```sh
scripts/update.sh 0.1.1
```

What it does: validates the version (exact `MAJOR.MINOR.PATCH[-pre]`, no `v`, not `latest`), **pulls the image first** (if that
fails nothing has changed), shows the image digest, writes the version to `.env`, recreates the containers (all rooms end,
clients reconnect), waits until healthy, runs `verify.sh`, and **rolls back automatically** to the previous version if either
fails (`--no-rollback` to keep the failed state for inspection; `--no-pull` for an image you loaded yourself).

The images are not signed (see the product's release notes); compare the printed digest with the one you trust:
`docker buildx imagetools inspect ghcr.io/wi-wissen/cometcast-server:0.1.1`.

Update the STUN service the same way: edit the pinned `coturn/coturn:<tag>@sha256:...` line in `compose.yaml`, run `scripts/check-stun.sh` (starts that image with `config/stun.conf` and checks it) and `scripts/up.sh`. Another coturn version can know other options: a wrong option is a start error or a `Bad configuration format` warning, which `check-stun.sh` turns into a failure.

Update Caddy by editing the pinned image line (tag and digest) in `compose.yaml` (`caddy:2.11.9@sha256:...`), then
`scripts/check-caddyfile.sh` (validates the Caddyfile with the new image) and `scripts/up.sh`. Get a digest with
`docker buildx imagetools inspect caddy:<tag>` (the line `Digest:` of the index).

### 10.4 Roll back

```sh
scripts/rollback.sh            # to the most recent earlier version in .state/version-history
scripts/rollback.sh 0.1.0      # to a named version (pulled again if it is gone from this host)
```

The history file is local to the host and ignored by git. If it is missing, name the version.

### 10.5 Abuse handling

What the server does by itself (open-mode defaults, per client address; IPv6 counts per /64, and per /48 with a higher
threshold): rate limits on connections, `create_room`, `join_room`, `/altcha/challenge`; caps on open connections and rooms per
address and in total; ALTCHA difficulty that rises with load and recent bad events; **temporary bans** after too many failed
joins (10 within 10 minutes: banned for 1 minute, then 5, then 30; the history is forgotten after an hour). A banned address
gets `403` with `Retry-After`, a rate-limited one `429` or the error `rate_limited` on the open connection.
All limits are unmeasured placeholders in the product.

What you can see: **bans, counters and limits are in memory, are not logged and cannot be listed.** There is no admin interface.
The only visibility is at the edge:

1. **Switch on Caddy's access log temporarily.** Decide first: it records visitors' IP addresses (personal data); the privacy
   notice of the web site must cover it and you should keep it off or short-lived. Add inside the site block of the
   `Caddyfile`, restart Caddy, and remove it afterwards:
   ```
   	log {
   		output stdout
   		format json
   	}
   ```
   ```sh
   docker compose restart caddy
   docker compose logs --no-log-prefix --since 10m caddy | jq -r 'select((.logger // "") | startswith("http.log.access")) | "\(.request.client_ip) \(.status) \(.request.uri)"' | sort | uniq -c | sort -rn | head -20
   ```
   (Tested locally: field names `request.client_ip` and `status`.) Many `429` and `403` for one address are the server's limits
   and bans at work. Many `101` or `200` for one address without matching legitimate use is what to block.
2. **Block an address or network at the edge.** `cp config/caddy.d/blocklist.caddy.example config/caddy.d/blocklist.caddy`,
   put the addresses in, then
   ```sh
   docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```
   The connection is closed without an answer, no restart, no rooms lost. Remove the lines the same way. (Tested locally.) The file
   is ignored by git (IP addresses are personal data). `ufw deny from ...` does **not** work for these ports (section 3.4).
3. **Unban early or reset the counters:** only by `docker compose restart cometcast-server` (ends all rooms).
4. **Tighten limits** only with measurements: add `limits.*` keys to `config/relay.toml` (reference table in the product repository's
   `bins/cometcast-server/README.md`), restart. Legitimate users behind one shared address (school, office) share one bucket, so
   lowering limits can lock them out.
5. **A flood the VPS cannot absorb** (bandwidth) is the provider's business: ask for their DDoS protection or a network filter. A
   CDN in front is **not** supported or tested: `X-Forwarded-For` and CORS would need re-checking (the product notes CORS behind a
   CDN as UNCERTAIN). As a last resort `docker compose stop caddy` takes the relay offline.
6. Keep a note of what you blocked and why, and remove entries that are no longer needed.

### 10.6 Backups: what state exists

| What | Where | Needed? |
| --- | --- | --- |
| STUN service | none | **No state**, no volume, no secret. |
| Rooms, bans, counters | server memory | **No state on disk** (confirmed by the server documentation). Nothing to back up; a restart ends all rooms and clears bans. |
| Configuration | this repository (`config/`, `Caddyfile`, `compose.yaml`) | In git. |
| `.env` | host only, no secrets inside | Keep a copy of the two values (version, domain). |
| `secrets/altcha_secret` | host only | Regenerate with `gen-secrets.sh --rotate` if lost (only puzzles in flight fail). |
| Caddy volume `cometcast-relay_caddy_data` | Docker volume | ACME account and the certificate with its private key. Not fatal to lose (a new certificate is requested), but Let's Encrypt limits duplicate certificates (currently 5 per week for the same names, **UNCERTAIN: check their current limits**), so repeated rebuilds can lock you out for days. |
| `config/caddy.d/blocklist.caddy` | host only | Your block list. |
| Version history `.state/` | host only | Convenience for rollback. |

Optional backup of the Caddy volume (tested locally, treat the archive as secret because it contains the private key):

```sh
docker run --rm -v cometcast-relay_caddy_data:/data:ro -v "$PWD":/backup \
  "$(awk '/image: &caddy_image/ { print $3 }' compose.yaml)" tar czf /backup/caddy-data.tgz -C /data .
chmod 600 caddy-data.tgz
```

Take a provider snapshot of the VPS before risky changes; otherwise rebuilding the host from this repository takes minutes.

### 10.7 Monitoring (no third-party service needed)

- **On the host:** Docker restarts crashed containers (`restart: unless-stopped`); health checks show in `docker compose ps`.
  `verify.sh` is the full check, including the certificate lifetime (it fails 14 days before expiry, which means Caddy's
  renewal did not work).
- **From a second machine** (a home server, another VPS), every 5 minutes with cron, using only this repository's two scripts
  and no Docker (needs `curl`, `openssl`, `python3`, a clone of this repository, `--no-compose` and an explicit `--origin`):
  ```
  */5 * * * * cd /opt/cometcast-relay && scripts/verify.sh --no-compose --quiet-header --origin https://cometcast.de >/tmp/relay-verify.out 2>&1 || logger -t cometcast-relay "verify FAILED: see /tmp/relay-verify.out"
  ```
  Send mail or a message from there in whatever way you already use (`mail`, a webhook of your own chat). **UNCERTAIN: not run
  as a cron job.** A simple alternative is an uptime check of `https://relay.cometcast.de/healthz` with any service you
  trust (that is a third party and optional).
- **What is not available:** the server has no metrics endpoint, so no counts of rooms or connections. Caddy can expose request
  metrics through its admin API (global option `servers { metrics }`, read inside the container at `127.0.0.1:2019/metrics`);
  this is not enabled and was not tried.
- Keep an eye on disk (`df -h`), pending host updates and the version of the product (new releases).

### 10.8 If the host is compromised (or you suspect it)

The relay holds no user data on disk, but a compromised relay is trusted for signalling: it sees offers, answers and ICE candidates
(including peers' network addresses) and could alter them. **UNCERTAIN: this repository does not verify whether the clients detect a
manipulated signalling channel (for example by checking DTLS fingerprints out of band); assume they might not.**

1. **Do not clean the machine, replace it.** Take a provider snapshot for later analysis (it stays offline), then stop the exposure:
   `docker compose down` or shut the VPS down, or remove it from DNS (set the A record to an address that serves nothing).
2. **Build a new VPS from scratch** with this runbook (new SSH keys, new `secrets/altcha_secret`, new Caddy volume, so a new certificate), start a version you have verified
   (the digest), run `verify.sh`, point DNS to it, destroy the old one when the analysis is done.
3. **Rotate everything that was on, or reachable from, the host:** SSH keys and any other credential stored there (GitHub tokens,
   deploy keys, DNS or provider API tokens), the DNS provider and VPS provider account passwords and 2FA if there is any doubt.
4. **Certificate:** the old private key was on the host. Revoke the certificate through any ACME client with the old key (for example
   `certbot revoke --cert-path ... --key-path ...` after restoring the files from the snapshot; **UNCERTAIN: not tried**).
   Caddy itself has no revoke command that was checked here.
5. **Find the cause** (logs from the snapshot, `docker compose logs`, auth log) before reusing anything. Typical causes: SSH password or key leaked, a
   compromised user in the `docker` group, an outdated host.
6. **Tell people:** publish a short notice, and check your legal duties (the relay may have handled IP addresses; a possible duty to
   notify under the GDPR within 72 hours is a question for the responsible person, this runbook gives no legal advice).
7. If the **image** is suspected: images are unsigned; compare digests with the release notes of the product repository, and rebuild
   from source (`deploy/Dockerfile` in the product repository) if in doubt.

### 10.9 STUN service

What it is: the compose service `stun`, **coturn 4.18.0 in STUN-only mode** (`config/stun.conf`, no secrets). It answers a
STUN Binding request ("which public address and port do you see for me?") on **UDP 3478** and nothing else. Browsers use that
answer to build the candidates for a direct connection across NATs. Why coturn: it is the program the product repository
already uses for TURN (licence: BSD-3-Clause according to its repository, **UNCERTAIN: not re-checked for the image**; no third-party service involved), its STUN-only mode is a documented option, and the
operator learns one program, not two. A smaller STUN-only program would also do; none was evaluated in this repository.

How it is locked down (all checked on a local run, section 12):

| Property | Setting |
| --- | --- |
| No relaying | `stun-only` (coturn ignores every TURN request) and `no-tcp-relay`. No users, no secret, no realm, no `no-auth`. A TURN Allocate request, also one made with `turnutils_uclient` and made-up credentials, gets **no answer at all** and no allocation. `scripts/stun-check.py` checks this on every `verify.sh` run; it was also run against a normal TURN server and **failed** it there, as it must. |
| Listeners | UDP 3478 only (`no-tcp`, `no-tls`; DTLS is off by default in 4.18). Published as `3478/udp` only. STUN over TCP/TLS is not offered: browsers use UDP for this and TCP would add nothing but a service to attack. |
| Small answers | A Binding answer is **32 bytes for a 20-byte request** (factor 1.6): header plus XOR-MAPPED-ADDRESS, no SOFTWARE, no RFC 3489 or RFC 5780 attributes (`no-rfc5780`, `no-software-attribute`; in 4.18 these are defaults, written down so a newer coturn cannot widen the answer silently). `stun-check.py` fails if the answer ever exceeds 3 times the request. |
| Garbage | Random bytes get no answer. |
| Container | not host networking (own Docker network `stun`, so it sees no host service); `read_only`, `tmpfs` for `/tmp`, user `nobody`, `cap_drop: ALL` with only `NET_BIND_SERVICE` added back (needed by the binary's file capability, effective capabilities are empty), `no-new-privileges`, `mem_limit 128m`, `pids_limit 256`, `cpus 0.5` (UNCERTAIN: guesses, never load-tested), image pinned by tag and digest, health check = a real Binding request (`turnutils_stunclient`). |
| Logs | No per-request log lines and no client addresses at the default verbosity. |
| Privacy | The service sees the source address of every request, as any STUN server does, and does not store it. Mention it in the privacy notice (the browser contacts this host on connect). |

**Residual risk, honestly: reflection and amplification.** STUN runs over UDP, and UDP source addresses can be forged. An attacker
can send Binding requests with a victim's address as the source, and the service then sends the victim 32-byte answers. The factor
is small (1.6) compared with DNS or NTP amplification, but it is not zero, and the relay's bandwidth becomes part of someone else's
attack. What is done: the smallest possible answer; **per-source and global rate limits at the host firewall**
(`firewall/stun-ratelimit.nft`: 100 packets/s per IPv4 address or IPv6 /64 with a burst of 200, 5000 packets/s in total; measured
on a local Docker run: of 1500 packets sent in one burst, 200 were let through and 1300 dropped; it also limits what a forged source
can make the service send to one victim to about 3 KB/s). What is NOT solved: many spoofed victims at once (each gets its own small
budget); a forged source can use up a real client's budget for a moment (the browser retries, the request may be lost); a large flood
of packets still reaches the host's network card before any rule (volume attacks are the provider's job, section 10.5 point 5);
nothing checks that a source address is real. The limits are guesses (**UNCERTAIN**), and no load test was run. If you see abuse,
lower the numbers in `firewall/stun-ratelimit.nft` or stop the service (`docker compose stop stun`): the relay keeps working,
connections then rely on the devices' own STUN fallbacks, if any, or on the same network.

Rate limit with ufw: ufw cannot filter a Docker-published port, so load `firewall/stun-ratelimit.nft` (own nft table, works next
to ufw). It is lost at reboot unless you make it permanent (**UNCERTAIN**, depends on the distribution; the note in `firewall/nftables.conf`
applies). With provider-level firewalls: allow UDP 3478 inbound there too.

Checks by hand:

```sh
scripts/check-stun.sh                                            # starts the pinned image with config/stun.conf on loopback and tests it
python3 -I scripts/stun-check.py --host relay.cometcast.de       # from any machine: binding, allocate refused, garbage ignored
docker compose logs stun | grep -E 'ERROR|Bad configuration'     # must print nothing
```

Not tested: the answer for a client behind a real NAT or from the internet (the local run reported the Docker bridge gateway as the
client address because the request came from the same machine); IPv6; load; Docker's behaviour for UDP port publishing on a real VPS
(with the normal iptables NAT it keeps the client's source address, which STUN needs; a userland proxy would replace it, as for IPv6).

## 11. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `up.sh`: `COMETCAST_VERSION ... must be an exact version` | Fix `.env`. |
| `docker pull` says `denied` or `not found` | The tag does not exist (yet), or the package is private. Check the tag list of the package on GitHub. |
| `up.sh` stops at `lint-config.sh` | Read the failing line; the invariants are listed in section 5. |
| Caddy does not get a certificate | DNS does not point here yet; 80/443 blocked by a provider firewall; Let's Encrypt rate limit. `docker compose logs caddy`. |
| `verify.sh`: TLS verify fails right after start | The certificate is not issued yet; wait for `certificate obtained successfully`. |
| Browser: CORS error or the WebSocket is refused (`403`) | The page's origin is not in `allowed_origins` (exact scheme and host, no path). Only the origin of the page counts, not the relay's. |
| `403` for everyone | The client address is a banned or wrong address: check the proxy address chain (section 8, last paragraph) and `trusted_proxies`. |
| `400` for every request | A trusted proxy sends a broken `X-Forwarded-For`; should not happen with this Caddyfile. |
| `429` / `rate_limited` | Limits per client address; many users behind one NAT hit the open-mode defaults. Do not lower them; raising them needs measurement. |
| `altcha_invalid` after a restart | `secrets/altcha_secret` missing or rotated; puzzles in flight fail once, clients fetch a new one. |
| Server container restarting | `docker compose logs cometcast-server`: exit code 2 means an invalid setting (the message names the key; unknown keys are errors); or the secret file is unreadable (owner `root:65532`, mode `0440`: re-run `sudo scripts/gen-secrets.sh`). |
| `caddy-init` or `caddy` cannot write `/data` | The volume is owned by someone else: `docker compose up -d --force-recreate caddy-init caddy`. |
| Port 80/443 already in use | Another web server on the host: stop or remove it; `bootstrap.sh` checks this. |
| `docker compose` complains about `COMETCAST_VERSION` | `.env` is missing or run from another folder. |
| Server exits with code 2, message about an unknown key `stun` | The server image is older than the `[stun]` support. Use a newer `COMETCAST_VERSION` (section 1). |
| `verify.sh`: `GET /ice-servers -> 404` | `[stun]` missing in `config/relay.toml` (or the restart after editing was forgotten), or a Caddyfile without `/ice-servers` in the path list. |
| `verify.sh`: STUN `no answer ... within 3 s` | UDP 3478 blocked (provider firewall, host firewall, `STUN_PORT` mismatch), the `stun` container is down (`docker compose ps`), or you are on a network that blocks UDP (`--no-udp`). |
| `verify.sh`: STUN `you are 172.x...` from another machine | Docker replaced the client address (a userland proxy is in the path, for example for IPv6 or a local test). STUN then reports the wrong address: browsers get useless candidates. Publish IPv4 only and check `docker compose ps` for `docker-proxy`. **UNCERTAIN: not seen on a real host.** |
| `stun` container stops at start | `docker compose logs stun`: a coturn option this version does not know (`ERROR`, `Bad configuration format`), or the config file is unreadable. Run `scripts/check-stun.sh`. |

## 12. What was tested, and what was not

Run locally on 2026-11-07 (Ubuntu 24.04 container, Docker Engine 29.9.2 started by hand, Compose 5.6.1, amd64), with the server image built
from the product repository's `deploy/Dockerfile` (commit `ef684e23`), Caddy 2.11.9 and Caddy's internal CA for `localhost`:

- Passed: `shellcheck` on all scripts, `bash -n`, `py_compile`, YAML parse and `yamllint`, `docker compose config`, `nft -c` on
  `firewall/nftables.conf`, `caddy validate` and `caddy fmt` on the Caddyfile, `lint-config.sh`, the vendored coturn render tests
  (164 checks).
- Full stack started (`scripts/up.sh`): both containers healthy with `read_only`, `cap_drop: ALL`, `no-new-privileges`, Caddy as UID 65532 on ports 80/443
  inside its container. `scripts/verify.sh`: 16 of 16 passed, and with a wrong origin the CORS and WebSocket checks failed as they should.
- A forged `X-Forwarded-For` sent by a client is replaced by Caddy with the address it saw (tested against an echo upstream).
- `scripts/update.sh`: a failing pull changes nothing; an update to another local tag worked; an update to a broken image rolled back automatically;
  `scripts/rollback.sh` worked. The Caddy block list (`abort`) blocked and unblocked after a reload. The access-log `jq` example and the Caddy volume backup
  command ran.
- The server image started with the `internal/config/server.example.toml` settings (without TLS).

STUN service (added later, also local, 2026-11-07, Docker 29.9.2, coturn 4.18.0 by digest, server image built from the product branch `open-stun` with the
`[stun]` change because no release contains it): `docker compose config`, `scripts/lint-config.sh` (with eleven mutated copies: each broken STUN setting was caught),
`scripts/check-stun.sh`, `shellcheck`, `yamllint`, `caddy validate`/`fmt` with `/ice-servers` passed through, `nft -c` on both firewall files. Full stack started with
`scripts/up.sh` (3 long-running containers healthy, the stun container read-only, user `nobody`, effective capabilities none, 128 MiB and 256 pids and 0.5 CPU applied).
`scripts/verify.sh --ip 127.0.0.1 --cacert ... --min-days 0`: 22 of 22 passed, including `/ice-servers` (STUN only, no credentials, CORS) and the UDP checks
(Binding success, 32 bytes for 20, Allocate ignored, garbage ignored). `turnutils_uclient` with made-up credentials got **no allocation** from the STUN service, and got a
relay address from a normal coturn started for comparison (positive control); `stun-check.py` failed that normal server on the Allocate check, as it should. A burst
of 30 000 Binding requests left the service healthy at about 8 MiB. `firewall/stun-ratelimit.nft` was loaded: of 1500 packets sent in one burst through Docker's
published port 200 passed and 1300 were dropped (counter), and the same in an isolated network namespace (3000 sent, 3000 received without the rules, 200 with them);
the table was removed afterwards. **Not run (STUN):** a request from outside (the answer showed the Docker bridge address because the request came from the
same machine); a real browser connection across two networks; IPv6; real load; `bootstrap.sh`'s new UDP port check (the test container has no `ss`); a permanent nftables setup; `ufw.sh --apply`.

**Not run (UNCERTAIN):** a real VPS; a real public certificate from Let's Encrypt and its renewal; the real DNS names;
the real GitHub Pages web app against the relay, from two browsers; IPv6; which client address Caddy sees for remote clients through Docker's
port publishing; `ufw.sh --apply` and a permanent nftables setup; `bootstrap.sh` on a real Debian/Ubuntu VPS (it ran only in the test container);
arm64; the pull of a published image from ghcr.io (no release exists yet); load, memory and pid limits; the cron monitor; `scripts/sync-from-product.sh` from
the GitHub URL; the `internal/` profile on a real network; the CI workflow on GitHub.

## 13. Decisions that belong to the owner

1. **Hosting provider and region** (and whether the provider offers DDoS protection and a provider-side firewall); instance size.
2. **DNS provider and registrar steps:** the A record for `relay.cometcast.de` at the DNS provider of `cometcast.de`; an AAAA record only after IPv6 was tried.
3. **STUN for the public relay: decided** (by the project lead on the owner's behalf, product concept "direct WebRTC first, then internal server, then the
   receiver's own Wi-Fi"): the open-mode server lists a STUN server at `/ice-servers` (`[stun]`, product repository) and this repository runs it (section 10.9, no
   third party). TURN stays internal-only. Still the owner's: whether UDP 3478 on this host and the reflection risk of section 10.9 are acceptable, the privacy
   notice (the browser contacts this host for STUN), and the first server release that contains `[stun]`.
4. **Access log and privacy notice:** whether Caddy logs client addresses (off by default), for how long, and the matching privacy page on the web site.
5. **Who gets notified** by the monitor, and who may log in to the host.
6. **The first image version** to run (no release exists yet), and whether to also verify digests against release notes.
7. **Whether more origins** (for example `https://www.cometcast.de` if it is ever served directly) belong in `allowed_origins`.
