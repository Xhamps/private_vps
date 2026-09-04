# LiteLLM Proxy on this VPS — design

**Date:** 2026-09-04  
**Status:** approved (approach 1 — Keycloak-shaped stack)  
**Scope:** LiteLLM Proxy + Postgres as an infra stack behind Traefik + Twingate

## Goal

Run [LiteLLM Proxy](https://docs.litellm.ai/) as a private LLM gateway at `https://litellm.<domain>`, reachable only over Twingate, using the official quickstart shape (gateway + Postgres) adapted to this repo’s Traefik / no-published-ports / deploy patterns.

## Decisions

| Topic | Choice |
|---|---|
| Placement | Infra stack in this repo (`litellm/`), not a separate `/opt/apps/` project |
| Hostname | `litellm.<domain>` |
| Models / provider keys | Not in CI for v1 — configure later in LiteLLM UI (`STORE_MODEL_IN_DB=True`) |
| Shape | Keycloak-style: app on `proxy` + Traefik labels; Postgres on `internal` only |
| Access | Traefik `internal-only@file` middleware (Twingate) |
| Image | Pin `docker.litellm.ai/berriai/litellm:v1.99.0` (official mirror of `ghcr.io/berriai/litellm`; avoids this repo’s deploy path that treats any `ghcr.io` image as an org package) |
| Secrets | GitHub secret `ENV_litellm` → pipeline writes `/opt/infra/litellm/.env` |
| Reference compose | [docs.litellm.ai/docker-compose.yml](https://docs.litellm.ai/docker-compose.yml) |

## Architecture

```
Twingate client → Connector → Traefik :443
  Host(`litellm.<domain>`) + middleware internal-only@file
       → litellm:4000 (proxy network)
            → postgres (internal network only)
                 volume: /opt/data/litellm-db
```

- No `ports:` on either service (Traefik is the only publisher on the host).
- Without Twingate: public requests to `litellm.<domain>` get **403**.
- With Twingate: UI + OpenAI-compatible API at `https://litellm.<domain>`.
- Master key authenticates admin/API; salt encrypts virtual keys at rest in Postgres.

## Components

| Piece | Role |
|---|---|
| `litellm/docker-compose.yml` | `litellm` + `db` (postgres), networks, Traefik labels, healthchecks |
| `litellm/.env.example` | Documents `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `LITELLM_DB_PASSWORD`, `DOMAIN` |
| `.github/workflows/deploy.yml` | Add `litellm` to the stack matrix |
| `docs/runbook.md` | Twingate Resource row + first-deploy / secret notes |
| `README.md` | List `litellm/` in layout table |

### Compose behavior (adapted from official quickstart)

- `litellm` env: `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `DATABASE_URL`, `STORE_MODEL_IN_DB=True`
- `DATABASE_URL`: `postgresql://litellm:${LITELLM_DB_PASSWORD}@db:5432/litellm`
- Traefik: `Host(\`litellm.${DOMAIN}\`)`, `tls.certresolver=le`, `middlewares=internal-only@file`, service port `4000`
- Postgres: user/db `litellm`, password from `LITELLM_DB_PASSWORD`, data under `/opt/data/litellm-db`
- Networks: `proxy` (external) + `internal` (compose-local); DB only on `internal`

## Secrets

GitHub secret **`ENV_litellm`** (multiline):

```
LITELLM_MASTER_KEY=sk-<long-random>
LITELLM_SALT_KEY=<long-random>
LITELLM_DB_PASSWORD=<long-random>
```

`DOMAIN` remains the repo variable (injected by deploy like other stacks). Do not rotate the salt casually — it encrypts stored virtual keys.

## Twingate Admin (manual)

Add Resource (same pattern as n8n / Keycloak):

| Alias | Address |
|---|---|
| `litellm.<domain>` | `litellm.<domain>` (TCP 443) |

Grant your user access. Connector must already be online.

## Data flow

1. Set `ENV_litellm` in GitHub.
2. Push `litellm/` + deploy matrix change → CI rsyncs to `/opt/infra/litellm`, writes `.env`, `compose up`.
3. LiteLLM waits for Postgres healthy, runs migrations, listens on 4000.
4. Traefik discovers labels → routes `litellm.<domain>` behind `internal-only`.
5. Operator opens Twingate → UI → adds models/provider keys.
6. Clients call `https://litellm.<domain>/v1/...` with virtual keys or master key (over Twingate).

## Error handling

- Missing/invalid secrets: proxy crash-loop or failed DB/auth — fix `ENV_litellm` and redeploy stack `litellm`.
- DB unhealthy: `depends_on` condition blocks litellm start until `pg_isready`.
- 403 with Twingate off: expected. Still 403 with Twingate on: Resource hostname/port, connector online, Traefik allowlist includes VPS public IP (existing Twingate runbook).
- Image pull failure: pin/tag typo or GHCR reachability — check compose tag and registry access from the VPS.

## Verification

1. `docker compose -f /opt/infra/litellm/docker-compose.yml ps` → both services healthy/running.
2. Twingate **off**: `curl -sI https://litellm.$DOMAIN` → **403**.
3. Twingate **on**: UI reachable; master key works for admin.
4. No host port publish: compose has no `ports:` (except Traefik stack unchanged).
5. Deploy matrix includes `litellm`; `workflow_dispatch` stack `litellm` works.

## Out of scope (v1)

- Provider API keys / `config.yaml` in the repo
- Uptime Kuma probe (optional manual add later)
- Redis / multi-replica / spend-log sidecar
- Public (non-Twingate) access to the gateway
- Automating Twingate Resource creation via API
