# Security

## Reporting

Report problems in this repository's scripts or configuration, or a weakness of the running relay, **privately**:
GitHub "Report a vulnerability" (Security tab of this repository) if it is enabled, otherwise the contact address on
<https://cometcast.de> (the imprint page; **UNCERTAIN: still a placeholder there**). Please do not open a public issue
for a vulnerability. Problems in the server code itself belong to the product repository
([wi-wissen/CometCast](https://github.com/wi-wissen/CometCast)).

## Scope and rules for this repository

- No secrets, keys, certificates, `.env` files or IP address lists in git (`.gitignore` excludes them). If one was
  committed, treat it as leaked: rotate it, then remove it from history.
- The relay holds no user data on disk. What it can see (signalling messages, client addresses in memory) is described in
  [docs/SETUP.md](docs/SETUP.md) section 10.8, together with what to do after a compromise.
