# private_vps

Infrastructure repo for a single Hostinger VPS (Ubuntu 24.04) hosting multiple projects as Docker Compose stacks. [Traefik](traefik/) is the only container exposed to the internet — it auto-routes each `*.yourdomain.com` subdomain to its container via Docker labels and issues Let's Encrypt certificates automatically. Deploys are GitHub Actions → GHCR → SSH; monitoring is Prometheus + Grafana + Alertmanager + Uptime Kuma.

```
                        Internet
                           │
                    ┌──────▼──────┐
      :80 / :443 →  │   Traefik   │  (only published ports on the host)
                    └──────┬──────┘
              Docker network: proxy
        ┌──────────┬───────┴───────┬─────────────┐
   app1.domain  app2.domain   grafana.domain  status.domain
```

Full design and rationale: [docs/implementation-plan.md](docs/implementation-plan.md) · Operations: [docs/runbook.md](docs/runbook.md)

## Layout

| Path | Purpose |
|------|---------|
| `bootstrap.sh` | One-time server setup — the only manual step |
| `traefik/` | Edge proxy: TLS, 80→443 redirect, Docker auto-discovery |
| `monitoring/` | Prometheus, node-exporter, cAdvisor, Grafana, Alertmanager, Uptime Kuma |
| `project-template/` | Copy into each new project repo (Dockerfile, compose, deploy workflow) |
| `.github/workflows/deploy.yml` | Syncs configs to the VPS and restarts stacks on push to `main` |

On the VPS: configs in `/opt/infra` and `/opt/apps/<name>`, persistent data in `/opt/data` (never synced). Config and secrets live in GitHub Actions Variables/Secrets — the pipeline writes each stack's `.env` on the VPS at every deploy. Nothing secret in git, nothing hand-edited on the server.

## Setup

1. **Prerequisites**: VPS (8 GB+ RAM), Ubuntu 24.04, DNS `A` records for `yourdomain.com` and `*.yourdomain.com` → VPS IP, your SSH key installed for root.
2. **Bootstrap** (once):
   ```bash
   scp bootstrap.sh root@VPS_IP:/tmp/ && ssh root@VPS_IP "bash /tmp/bootstrap.sh"
   ```
   It hardens SSH (test key login before closing the session!), sets up ufw/fail2ban/Docker, and prints a CI keypair.
3. **GitHub secrets** (this repo + every project repo): `SSH_HOST`, `SSH_USER` (`deploy`), `SSH_KEY` (printed by bootstrap — delete from the VPS after copying).
4. **GitHub config**: variable `DOMAIN`, secret `ENV_monitoring` (Grafana password), optional per-app `ENV_FILE` secret — details in [runbook step 3](docs/runbook.md#first-deploy-order-matters).
5. **Push to `main`** → Traefik and monitoring go live. Verify with the whoami test in the runbook.

From here the server is never configured by hand again — every change goes through git.

## Adding a project

Copy `project-template/` into a new private repo, rename `myapp` and pick a subdomain, add the SSH secrets, push to `main`. Built → pushed to GHCR (tagged by git SHA) → deployed → TLS'd → routed. No DNS work needed. Add an Uptime Kuma check.

Rollback: re-deploy with the previous SHA — see [runbook](docs/runbook.md#rollback).
