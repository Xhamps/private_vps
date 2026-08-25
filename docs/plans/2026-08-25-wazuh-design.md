# Wazuh on this VPS — design

**Date:** 2026-08-25
**Status:** approved
**Scope:** this Hostinger VPS only (no remote agents)

## Goal

Run Wazuh 4.14.7 as an infra stack in this repo: indexer + manager + dashboard in Docker behind Traefik, native `wazuh-agent` on Ubuntu, Keycloak SAML SSO at `https://wazuh.<domain>`.

## Decisions

| Topic | Choice |
|---|---|
| Coverage | This VPS only |
| Central components | Official wazuh-docker single-node, images `4.14.7` (not 5.x beta) |
| Agent | Native Ubuntu package, same version. No Docker agent in v1 |
| Auth | Keycloak SAML client `wazuh-saml` in existing `XhampsHub` realm. Built-in `admin` stays as break-glass |
| Dashboard URL | `https://wazuh.<domain>` |
| Public ports | Unchanged: only Traefik publishes 80/443 |
| Agent ports | Manager publishes `127.0.0.1:1514` and `127.0.0.1:1515` only |
| Data | `/opt/data/wazuh/` — never rsynced |
| Indexer heap | 1 GB (`-Xms1g -Xmx1g`) |

## Architecture

```
Internet
   │  :443 (Traefik only)
   ▼
Traefik ── https://wazuh.<domain> ──► wazuh.dashboard :5601
                                         │
                         internal Docker network
                         │                 │
                   wazuh.manager      wazuh.indexer
                         ▲
                         │ 127.0.0.1:1514 / 1515
                   wazuh-agent (systemd on Ubuntu)
```

- Dashboard is the only Wazuh service on the `proxy` network. Traefik terminates Let’s Encrypt and proxies HTTPS to the dashboard’s existing TLS port. The dashboard cert is self-signed; Traefik skip-verify is scoped to this backend only (`serversTransport` in a Traefik file provider).
- Manager, indexer, and dashboard share a private `internal` network. 9200, 55000, and 514 are not published.
- Localhost `1514`/`1515` is the only `ports:` exception outside Traefik. It exists so the host agent can enroll without putting those ports on the internet. Compose must keep the `127.0.0.1` bind. Changing it to `0.0.0.0` would punch ufw via Docker.
- Certs are generated once (official `wazuh-certs-generator`) into `/opt/data/wazuh/certs` and never overwritten on later deploys.

## Components

| Piece | Role |
|---|---|
| `wazuh/docker-compose.yml` | Indexer, manager, dashboard. `proxy` + `internal`. Healthchecks. Localhost 1514/1515. |
| `wazuh/config/` | Official 4.14.7 manager/indexer/dashboard YAML plus SAML security config. |
| `wazuh/generate-indexer-certs.yml` | One-shot cert generator. Deploy runs it only if the cert dir is empty. |
| `wazuh/.env.example` | Documents `ENV_wazuh`. Pipeline writes `/opt/infra/wazuh/.env` (mode 600). |
| `/opt/data/wazuh/` | Indexer data, manager state, certs. Bootstrap creates dirs. |
| `bootstrap.sh` | Persist `vm.max_map_count=262144`, data dirs, install `wazuh-agent` 4.14.7 from Wazuh apt, `apt-mark hold`, enable systemd. Idempotent. |
| `.github/workflows/deploy.yml` | Add `wazuh` to the stack matrix. After compose is up, enroll/restart the host agent against `127.0.0.1` if not already connected. |
| Keycloak | Manual once: SAML client `wazuh-saml`, role `wazuh-admins`, mapper `Roles`. Same pattern as the Grafana OIDC client. |
| Traefik | Dashboard labels + file-provider `serversTransport` with `insecureSkipVerify` for this backend only. No new entrypoints. |
| Uptime Kuma | One HTTPS check for `wazuh.<domain>` (manual, like other apps). |

## Data flow

1. Host agent tails Ubuntu logs (auth, syslog, fail2ban), runs FIM/SCA/rootcheck, enrolls once at `127.0.0.1:1515` with the enrollment password, then ships events to `127.0.0.1:1514`.
2. Filebeat in the manager writes alerts to `wazuh.indexer:9200` over `internal`, TLS with generated certs.
3. Browser → Traefik → dashboard. Login is Keycloak SAML or break-glass `admin`. Dashboard talks to indexer and manager API (`https://wazuh.manager:55000`) only on `internal`.
4. `ENV_wazuh` in GitHub Actions → pipeline writes `.env` on each deploy. Nothing secret in git.
5. Push to `main` rsyncs `wazuh/` and runs compose. Cert generator and agent enroll are idempotent.

## Error handling

- Indexer is the RAM hog; it OOM-kills first. Heap stays at 1 GB. First boot needs a long Compose `start_period`.
- Certs are write-once. Regenerating them would break inter-container TLS.
- Failed agent enroll leaves the package installed; the next deploy retries. Re-runs do not wipe `/var/ossec`.
- SAML misconfig: break-glass `admin` still works (`multiple_auth_enabled`). Missing role mapping → login succeeds, UI is empty/forbidden; fix in Keycloak, do not recreate the stack.
- Traefik label mistakes 404 the same way Grafana would.

## Verification

1. Three containers running (healthy); host `wazuh-agent` active.
2. 1514/1515 listen on `127.0.0.1` only. 9200, 55000, 514, 5601 are not on `0.0.0.0`.
3. `curl -I https://wazuh.<domain>` is 200/302 with Let’s Encrypt, not the dashboard self-signed cert.
4. Break-glass `admin` reaches the UI.
5. An `XhampsHub` user with `wazuh-admins` gets admin dashboard access.
6. Agents → Summary shows this VPS active.
7. Uptime Kuma check added.

Rollback: previous git SHA / `workflow_dispatch` stack `wazuh`. Compose down does not uninstall the agent.

## Out of scope (v1)

- Docker wazuh-agent container
- Remote-agent ports on the internet
- Wazuh 5.x
- New Keycloak realm
- Automating the Keycloak SAML client
- OpenID (unofficial) instead of SAML
- Docker listener / extra Python deps on the host
- Publishing 9200, 55000, or 514
