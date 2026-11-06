# CometCast-Relay

Operations repository for the public Comet Cast relay server (planned host name
`relay.cometcast.de`, which does **not exist yet**).

The server code itself (`cc-server`, the `cometcast-server` program) lives in the main repository
[wi-wissen/CometCast](https://github.com/wi-wissen/CometCast). This repository is for running it:
deployment files, configuration templates and the setup guide.

> **Status: skeleton.** The deployment files are still in the main repository under `deploy/`
> (Dockerfile, Compose file, coturn template, example config) and are tested there together with
> the server code. They move here in the last step of the project, when the relay is set up.
> Docker and coturn have never been run; treat every file as unverified until the first real
> deployment.

## What the relay does

- Mediates connections: clients find each other with a room code and exchange WebRTC offers and
  answers. The open server never stores or relays images or files.
- Optional TURN relay (coturn) for networks that block direct connections.
- Protects itself with rate limits, bans and a proof-of-work check (ALTCHA) for the open mode.

See `docs/server.md` and `docs/protocol.md` in the main repository for the details.

## Contents

| Path | Content |
| --- | --- |
| [docs/SETUP.md](docs/SETUP.md) | Checklist for setting up `relay.cometcast.de` |
| `LICENSE` | GPL-3.0, same as the main repository |

## Licence

GPL-3.0-or-later, see `LICENSE`. Contributions follow the CLA of the main repository
([CLA.md](https://github.com/wi-wissen/CometCast/blob/main/CLA.md)).
