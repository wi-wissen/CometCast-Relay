# Setting up relay.cometcast.de

A checklist, not a tested procedure. **Uncertain:** nothing here has been run; the Docker image and
coturn have never been started. Do a dry run on a test host first.

## Before you start

1. Decide the mode: `open` (public, ALTCHA always on, mediation only) or `internal` (inside an
   organisation, TURN credentials, larger limits). The default relay is `open`.
2. A Linux host with a public IPv4 address (IPv6 optional) and Docker with the Compose plugin.
3. DNS: an `A` (and `AAAA`) record for `relay.cometcast.de`. Optional SRV record for discovery:
   `_cometcast._tcp.<your-domain>  SRV  0 0 443 relay.cometcast.de.`
4. A TLS certificate for the host name (for example from Let's Encrypt). The server reads the
   certificate and key files once at start, so a renewal needs a restart.

## Steps

1. Get the deployment files from the main repository, directory `deploy/`
   (`Dockerfile`, `docker-compose.yml`, `coturn/`, example config).
2. Copy the example config, set the mode, the listen address and the certificate paths. Never
   commit secrets. Use `secret_file` for the ALTCHA and TURN secrets (at least 16 characters).
3. Generate the coturn configuration with `coturn/render.sh` (it validates the inputs and writes the
   file with mode 600).
4. Open the firewall: TCP 443 (server), UDP/TCP 3478 and the relay port range for coturn.
5. Start with `docker compose up -d` and check `https://relay.cometcast.de/healthz`.
6. Test from a client on another network: the web app creates a room and a second browser joins it.
7. Watch the logs for rate-limit and ban messages during the first days. All limits are placeholders
   (measurement point 8 in the main repository).

## Not done yet

- Image tags and the base images are unverified assumptions.
- A monitoring or metrics endpoint does not exist.
- Certificate reload without a restart is not built.
