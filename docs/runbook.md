# Runbook

## First deploy (order matters)

1. Phase 0 done (VPS + DNS wildcard + SSH key).
2. `scp bootstrap.sh root@VPS_IP:/tmp/ && ssh root@VPS_IP "bash /tmp/bootstrap.sh"` — it generates a CI keypair and prints instructions (never the key itself). Fetch the private key over SSH, save it as the `SSH_KEY` secret (plus `SSH_HOST`, `SSH_USER`), then delete it from the VPS.
3. In GitHub → Settings → Secrets and variables → Actions (org-level where shared):
   - **Variable** `DOMAIN` = `yourdomain.com` (this repo + every project repo)
   - **Secret** `ENV_monitoring` = `GRAFANA_ADMIN_PASSWORD=<openssl rand -hex 16>`
   - Per project repo, optional **secret** `ENV_FILE` = multiline `KEY=value` block with that app's secrets.

   The pipeline assembles each stack's `.env` on the VPS from these at every deploy (mode 600) — never create or edit `.env` files on the VPS by hand.
4. Push this repo to `main` → Traefik + monitoring go live.
5. Verify Traefik with a throwaway whoami:
   ```bash
   docker run -d --rm --name whoami --network proxy \
     -l traefik.enable=true \
     -l 'traefik.http.routers.whoami.rule=Host(`test.yourdomain.com`)' \
     -l traefik.http.routers.whoami.tls.certresolver=le \
     traefik/whoami
   curl https://test.yourdomain.com   # valid cert + response, then: docker stop whoami
   ```
6. Grafana at `https://grafana.yourdomain.com` — import dashboards 1860 (node-exporter), 14282 (cAdvisor), 17346 (Traefik).
7. Uptime Kuma at `https://status.yourdomain.com` — create admin, add one HTTPS check per subdomain (enable cert-expiry notification, <14 days).
8. Telegram alerts: create bot via @BotFather, save its token as the `TELEGRAM_BOT_TOKEN` Actions secret (the pipeline writes it to the VPS on each monitoring deploy), set `chat_id` in `monitoring/alertmanager/alertmanager.yml`, push.

## Adding a new project

1. Copy `project-template/` into a new private repo; rename `myapp`, pick the subdomain.
2. Add secrets `SSH_HOST` / `SSH_USER` / `SSH_KEY` (or org secrets).
3. Push to `main`. No DNS work (wildcard). Add an Uptime Kuma check.

## Rollback

```bash
ssh deploy@VPS "cd /opt/apps/<name> && TAG=<old-git-sha> docker compose up -d"   # shell env overrides the .env TAG
```
Or re-run the old workflow run from the GitHub Actions UI.

## Quarterly checklist

- `ssh deploy@VPS "cat /var/run/reboot-required 2>/dev/null; docker system prune -f; sudo zgrep 'Ban' /var/log/fail2ban.log* | tail"`
