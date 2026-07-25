# VPS Implementation Plan

**Project:** Private VPS — multi-project Docker hosting with automated deploys and monitoring
**Provider:** Hostinger VPS · **OS:** Ubuntu 24.04 LTS · **Date:** 2026-07-25

---

## 1. Architecture Overview

One VPS runs Docker. **Traefik** is the only container exposed to the internet (ports 80/443). Every project is its own Docker Compose stack attached to a shared Docker network (`proxy`). Traefik watches the Docker socket and auto-routes each subdomain to its container based on labels, issuing Let's Encrypt certificates automatically.

```
                        Internet
                           │
                    ┌──────▼──────┐
      :80 / :443 →  │   Traefik   │  (only published ports on the host)
                    └──────┬──────┘
              Docker network: proxy
        ┌──────────┬───────┴───────┬─────────────┐
   app1.domain  app2.domain   grafana.domain  status.domain
   (project 1)  (project 2)   (monitoring)    (Uptime Kuma)
```

**Key decisions made:**

| Concern            | Choice                                   | Why |
|--------------------|------------------------------------------|-----|
| Edge proxy         | Traefik (instead of HAProxy)             | Auto-discovers containers via labels; automatic Let's Encrypt certs; zero config per new subdomain |
| Deploys            | GitHub Actions → GHCR → SSH              | Build logs in GitHub, image tagged by git SHA, controlled rollbacks |
| Registry           | GHCR (ghcr.io), private images           | Free, same permissions as the (private) repos |
| Monitoring         | Prometheus + Grafana + node-exporter + cAdvisor + Alertmanager, plus Uptime Kuma | Full metrics/alerting + simple uptime checks |
| OS                 | Ubuntu 24.04 LTS                         | LTS until 2029, Docker/ufw/fail2ban first-class, largest ecosystem |
| DNS                | Wildcard `*.yourdomain.com` A record → VPS IP | Never touch DNS again when adding a project |

**Golden rules:**

1. Only Traefik has `ports:` in its compose file. No other container publishes ports (this is also what keeps Docker from bypassing ufw).
2. The server is only ever changed by the CI/CD pipeline. Never hand-edit configs on the VPS; if you hot-fix, mirror it back to the repo immediately.
3. Secrets never live in git. They live in `.env` files on the VPS (`/opt/…/.env`) or GitHub Actions secrets.
4. Configs live under `/opt/infra` and `/opt/apps`; persistent data lives under `/opt/data`. rsync never touches `/opt/data`.

---

## 2. Repository Layout

**This repo (`private_vps`, private)** — the infrastructure repo:

```
private_vps/
├── docs/                        # this plan + runbooks
├── bootstrap.sh                 # one-time server setup (run manually)
├── traefik/
│   ├── docker-compose.yml
│   └── traefik.yml              # static config (entrypoints, ACME resolver)
├── monitoring/
│   ├── docker-compose.yml       # prometheus, grafana, node-exporter, cadvisor, alertmanager, uptime-kuma
│   ├── prometheus/prometheus.yml
│   ├── prometheus/alert-rules.yml
│   └── alertmanager/alertmanager.yml
└── .github/workflows/deploy.yml # rsync configs + docker compose up on push to main
```

**Each project repo (private)**:

```
project-x/
├── Dockerfile
├── docker-compose.yml           # joins the external `proxy` network, Traefik labels, healthcheck
└── .github/workflows/deploy.yml # build → push to GHCR (tag = git SHA) → SSH deploy
```

**On the VPS:**

```
/opt/infra/          # synced from this repo (traefik/, monitoring/)
/opt/apps/<name>/    # synced per project repo (compose + .env)
/opt/data/           # named volumes & persistent data — never synced, backed up nightly
```

---

## 3. Implementation Phases

### Phase 0 — Prerequisites (before the VPS exists)

- [ ] Buy Hostinger VPS plan — **8 GB RAM minimum** (KVM 2/4 tier): monitoring stack alone idles at ~1 GB.
- [ ] Choose **Ubuntu 24.04 LTS** (minimal template if offered), x86_64.
- [ ] DNS: create `A` record for `yourdomain.com` → VPS IP, and wildcard `A` record `*.yourdomain.com` → VPS IP.
- [ ] Have your personal SSH public key ready.

### Phase 1 — Bootstrap (one-time, manual)

The only manual phase. `bootstrap.sh` lives in this repo but is copied over by hand (private repo ⇒ raw curl won't work):

```bash
scp bootstrap.sh root@VPS_IP:/tmp/ && ssh root@VPS_IP "bash /tmp/bootstrap.sh"
```

The script must (idempotently):

- [ ] `apt update && apt upgrade`, install `unattended-upgrades`, `curl`, `git`, `rsync`.
- [ ] Create `deploy` user (sudo group), install your SSH public key.
- [ ] Harden SSH — `/etc/ssh/sshd_config.d/hardening.conf`: `PasswordAuthentication no`, `PermitRootLogin no`. **Test key login in a second terminal before closing the root session.**
- [ ] **ufw**: default deny incoming / allow outgoing; allow `OpenSSH`, `80/tcp`, `443/tcp`; enable.
- [ ] **fail2ban**: install; `/etc/fail2ban/jail.local` with `[sshd] enabled = true`, `bantime = 1h`, `findtime = 10m`, `maxretry = 5`; enable service. Verify: `fail2ban-client status sshd`.
- [ ] **Docker**: official repo via `curl -fsSL https://get.docker.com | sh` (not Ubuntu's `docker.io`); `usermod -aG docker deploy`; log rotation in `/etc/docker/daemon.json` (`max-size: 10m`, `max-file: 3`); enable service.
- [ ] `docker network create proxy`.
- [ ] Create `/opt/infra`, `/opt/apps`, `/opt/data` owned by `deploy`.
- [ ] Generate a **dedicated CI SSH keypair** (`ssh-keygen -t ed25519`) for the `deploy` user; print the private key once.

Then in GitHub → repo → Settings → Secrets and variables → Actions, add: `SSH_HOST` (VPS IP), `SSH_USER` (`deploy`), `SSH_KEY` (the CI private key). Add the same secrets to each project repo (or use an organization secret).

**From this point on, the server is never configured by hand again.**

### Phase 2 — Traefik (edge proxy)

- [ ] Static config `traefik/traefik.yml`: entrypoints `web` (:80, redirect → :443) and `websecure` (:443); Docker provider with `exposedByDefault: false`; Let's Encrypt resolver (TLS-ALPN or HTTP challenge), cert storage at `/opt/data/traefik/acme.json` (chmod 600).
- [ ] `traefik/docker-compose.yml`: publishes 80/443 (the **only** stack that does); mounts `/var/run/docker.sock:ro`; joins `proxy` network; `restart: unless-stopped`.
- [ ] Enable Traefik's Prometheus metrics endpoint (internal only) for the monitoring stack.
- [ ] Optional hardening later: docker-socket-proxy in front of the socket.
- [ ] Verify: deploy a `whoami` test container with labels → `https://test.yourdomain.com` serves with a valid certificate. Remove it after.

### Phase 3 — Infra CI/CD pipeline

- [ ] `.github/workflows/deploy.yml` in this repo, on push to `main`:
  1. Checkout; write `SSH_KEY` to `~/.ssh/id_ed25519`; `ssh-keyscan` the host.
  2. `rsync -az --delete traefik/ monitoring/ deploy@VPS:/opt/infra/` — scoped to config dirs only, never `/opt/data`, never `.env` files.
  3. SSH in: `cd /opt/infra/traefik && docker compose up -d --remove-orphans`, same for `monitoring/`.
- [ ] Add `concurrency: deploy` so two pushes can't deploy simultaneously.
- [ ] `docker compose up -d` is idempotent — safe on every push; containers restart only when config/image changed.
- [ ] Verify: edit a config, push, confirm change is live on the VPS within ~1 minute.

### Phase 4 — Monitoring stack

- [ ] `monitoring/docker-compose.yml` with: **Prometheus** (15–30 day retention, data in `/opt/data/prometheus`), **node-exporter**, **cAdvisor**, **Grafana** (data in `/opt/data/grafana`, exposed at `grafana.yourdomain.com` via Traefik labels, admin password from `.env`), **Alertmanager**, **Uptime Kuma** (`status.yourdomain.com`).
- [ ] Prometheus scrapes: node-exporter, cAdvisor, Traefik metrics, Prometheus itself.
- [ ] Alert rules: instance down, disk > 85 %, memory > 90 % sustained, container restart loops, TLS cert expiring < 14 days.
- [ ] Alertmanager receiver: Telegram / Slack / e-mail (credentials in `/opt/infra/monitoring/.env`, created once on the VPS).
- [ ] Grafana dashboards: import node-exporter (1860), cAdvisor/Docker, and Traefik community dashboards.
- [ ] Uptime Kuma: one HTTPS check per public subdomain + notification channel.
- [ ] Optional: Watchtower scoped **only** to the monitoring stack for auto-updates (apps stay pipeline-deployed).

### Phase 5 — Project deploy template

For each project repo:

- [ ] `Dockerfile` (multi-stage build where applicable, non-root user inside the container).
- [ ] `docker-compose.yml`: external `proxy` network; Traefik labels (`router.rule=Host(...)`, `tls.certresolver`, service port); a real `healthcheck`; `restart: unless-stopped`; **no `ports:`**.
- [ ] Workflow on push to `main`:
  1. Build image, push to GHCR: `ghcr.io/<owner>/<app>:<git-sha>` (+ `latest`). `GITHUB_TOKEN` with `packages: write` is enough.
  2. rsync the project's compose file to `/opt/apps/<name>/`.
  3. SSH deploy — **private images require login on the VPS**, done with the workflow's ephemeral token:
     ```bash
     echo "$GITHUB_TOKEN" | docker login ghcr.io -u <actor> --password-stdin
     cd /opt/apps/<name> && TAG=<git-sha> docker compose pull && TAG=<git-sha> docker compose up -d
     ```
     (Token expires when the run ends; nothing long-lived is stored on the VPS.)
- [ ] Rollback procedure: re-run deploy with the previous SHA tag (`TAG=<old-sha> docker compose up -d`). Document per project.
- [ ] Verify: push a change → new image on GHCR → live on subdomain; container healthcheck green.

### Phase 6 — Backups & operations

- [ ] Nightly backup (systemd timer or cron under the `deploy` user): dump databases + tar named volumes under `/opt/data` → **restic** to an S3-compatible bucket (Hostinger object storage or other). Include `acme.json`, Grafana and Uptime Kuma data.
- [ ] **Test a restore once** — a backup that has never been restored doesn't count.
- [ ] Backup-failure alert (e.g., restic exit code → Alertmanager or a healthchecks.io ping).
- [ ] Runbook in `docs/`: rollback steps, restore steps, "adding a new project" checklist.
- [ ] Quarterly: review `apt` pending reboots, Docker image sprawl (`docker system prune`), fail2ban logs.

---

## 4. Adding a New Project (steady-state checklist)

1. Create private repo from the project template (Dockerfile, compose, workflow).
2. Add the SSH secrets (or use org-level secrets).
3. Pick a subdomain — no DNS work needed (wildcard record).
4. Push to `main`. Done: built, deployed, TLS'd, routed, and visible in Grafana/cAdvisor automatically. Add one Uptime Kuma check.

---

## 5. Security Checklist (summary)

- SSH: keys only, no root login, fail2ban active, dedicated restricted key for CI.
- Firewall: ufw deny-by-default; only 22/80/443; no container publishes ports except Traefik.
- Secrets: GitHub Actions secrets + on-VPS `.env` files (600, owned by deploy); never in git.
- Registry: private GHCR images; VPS logs in per-deploy with ephemeral `GITHUB_TOKEN`.
- Docker socket mounted read-only into Traefik (socket-proxy as future hardening).
- Unattended security upgrades enabled; LTS OS supported to 2029.

---

## 6. Open Items / Decisions Still Pending

- Final domain name and subdomain map (app ↔ subdomain table).
- Alert channel choice (Telegram / Slack / e-mail) and credentials.
- Backup destination bucket and retention policy.
- Which projects go live first (affects VPS sizing validation).

**Next concrete step:** provision the VPS (Phase 0) and write `bootstrap.sh` (Phase 1). The starter-kit files for phases 1–5 can be generated from this plan.
