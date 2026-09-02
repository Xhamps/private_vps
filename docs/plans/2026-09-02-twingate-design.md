# Twingate on this VPS — design

**Date:** 2026-09-02  
**Status:** approved (option A)  
**Scope:** connector on this Hostinger VPS; private Traefik hosts via VPN; portfolio stays public

## Goal

Run a Twingate Connector on the VPS so private services (Grafana, Wazuh, n8n, Keycloak, Hermes, Traefik dashboard, Uptime Kuma) are reachable only over Twingate, while the portfolio site remains publicly reachable on Traefik.

## Decisions

| Topic | Choice |
|---|---|
| Approach | Traefik `IPAllowList` + Twingate Connector (`network_mode: host`) |
| Public apps | Portfolio only (separate project repo under `/opt/apps/`) — no `internal-only` middleware |
| Private apps | All Traefik-routed infra stacks in this repo |
| Connector deploy | Docker Compose stack `twingate/`, same CI path as other infra |
| SSH / UFW | Keep `OpenSSH` allowed — GitHub Actions deploy needs public `:22`. Twingate SSH Resource is optional for humans |
| Uptime Kuma | Keep HTTPS checks; allowlist includes Docker private ranges so Kuma’s hairpin probes still pass |
| ACME | Unchanged (`tlsChallenge`). Middleware is on routers only; LE still works |
| Secrets | GitHub secret `ENV_twingate` → pipeline writes `/opt/infra/twingate/.env` |

## Architecture

```
Internet                          Twingate client
   │                                    │
   │ :80/:443                           │ encrypted tunnel
   ▼                                    ▼
Traefik ◄── 127.0.0.1:443 ── Twingate Connector (host network)
   │
   ├── Host(portfolio…)     — no middleware → public
   └── Host(grafana|wazuh|…) — middleware internal-only → 403 unless source is loopback/private
```

- Connector uses `network_mode: host` and peers to Resources at `127.0.0.1:443` (and optionally `:22`).
- Traefik sees those connections as coming from `127.0.0.1` → `IPAllowList` allows them.
- Public visitors hit Traefik with a public source IP → private routers return **403**.
- Portfolio router has no allowlist middleware → stays open.

## Components

| Piece | Role |
|---|---|
| `twingate/docker-compose.yml` | `twingate/connector` image, `network_mode: host`, `restart: unless-stopped`, sysctl for ICMP |
| `twingate/.env.example` | Documents `TWINGATE_NETWORK`, `TWINGATE_ACCESS_TOKEN`, `TWINGATE_REFRESH_TOKEN` |
| `traefik/dynamic.yml` | Shared middleware `internal-only` (`ipAllowList` for `127.0.0.0/8` + RFC1918) |
| Private stack compose files | Label `traefik.http.routers.<name>.middlewares=internal-only@file` |
| Portfolio app compose | **Omit** that label (lives in its own repo; document the rule) |
| `.github/workflows/deploy.yml` | Add `twingate` to the stack matrix |
| `docs/runbook.md` | Admin Console setup, Resources list, verify steps, portfolio exception |
| `README.md` | One-line note that private hosts require Twingate |

### Allowlist CIDRs

```
127.0.0.0/8      # Twingate connector → localhost
10.0.0.0/8       # Docker / private
172.16.0.0/12    # Docker bridge / compose networks
192.168.0.0/16   # private LAN (unused on Hostinger; harmless)
```

Public client IPs are rejected. Datacenter VPS is not on a shared LAN with untrusted peers.

## Twingate Admin (manual, once)

1. Create Remote Network (e.g. `vps-prod`).
2. Add Connector → generate Access + Refresh tokens → put in `ENV_twingate`.
3. Resources (alias → address), grant your user access:

| Alias | Address |
|---|---|
| `grafana.<domain>` | `127.0.0.1:443` |
| `wazuh.<domain>` | `127.0.0.1:443` |
| `n8n.<domain>` | `127.0.0.1:443` |
| `keycloak.<domain>` | `127.0.0.1:443` |
| `hermes.<domain>` | `127.0.0.1:443` |
| `status.<domain>` | `127.0.0.1:443` |
| `traefik.<domain>` | `127.0.0.1:443` |
| `ssh-vps` (optional) | `127.0.0.1:22` |

Clients resolve the alias via Twingate and connect with SNI/`Host` intact so Traefik + LE certs still match.

## Data flow

1. Push `twingate/` + Traefik middleware + private-stack labels → deploy matrix syncs and `compose up`.
2. Connector authenticates with tokens from `.env`, registers on the Remote Network.
3. User enables Twingate client → HTTPS to `grafana.<domain>` tunnels to connector → `127.0.0.1:443` → Traefik → Grafana.
4. Without Twingate, same URL from the internet → Traefik middleware → 403.
5. Portfolio URL has no middleware → 200 for everyone.

## Error handling

- Missing / invalid tokens: connector container crash-loops; Admin shows Connector offline. Fix `ENV_twingate` and redeploy stack `twingate`.
- Forgot middleware on a private router: still public until next deploy with the label.
- Accidentally added middleware to portfolio: site returns 403 publicly — remove label and redeploy that app.
- Uptime Kuma red after lock-down: allowlist must include Docker ranges (not loopback-only).
- Do **not** remove UFW `OpenSSH` — CI would lose SSH.

## Verification

1. Connector green in Twingate Admin.
2. With Twingate **off**: `curl -sI https://grafana.<domain>` → **403**; portfolio → **200**.
3. With Twingate **on**: Grafana / Wazuh / etc. → **200** (or app login page).
4. Uptime Kuma checks for private hosts still green.
5. `workflow_dispatch` / push deploy still works over SSH.
6. `docker compose -f /opt/infra/twingate/docker-compose.yml ps` → running.

## Out of scope (v1)

- Closing public SSH / Twingate-only CI
- Removing wildcard DNS / DNS-01 ACME
- Terraform / Twingate API automation of Resources
- Portfolio compose changes in this repo (separate app repo)
