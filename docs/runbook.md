# Runbook

## First deploy (order matters)

1. Phase 0 done (VPS + DNS wildcard + SSH key).
2. `scp bootstrap.sh root@VPS_IP:/tmp/ && ssh root@VPS_IP "bash /tmp/bootstrap.sh"` — copy the printed CI key into GitHub secrets (`SSH_HOST`, `SSH_USER`, `SSH_KEY`), then delete it from the VPS.
3. Create once on the VPS (never in git):
   ```bash
   echo 'DOMAIN=yourdomain.com' > /opt/infra/.env
   printf 'DOMAIN=yourdomain.com\nGRAFANA_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 16)" > /opt/infra/monitoring/.env
   chmod 600 /opt/infra/.env /opt/infra/monitoring/.env
   ```
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
8. Telegram alerts: create bot via @BotFather, put token in `/opt/data/alertmanager/telegram.token` (chmod 600), set `chat_id` in `monitoring/alertmanager/alertmanager.yml`, push.

## Adding a new project

1. Copy `project-template/` into a new private repo; rename `myapp`, pick the subdomain.
2. Add secrets `SSH_HOST` / `SSH_USER` / `SSH_KEY` (or org secrets).
3. Push to `main`. No DNS work (wildcard). Add an Uptime Kuma check.

## Rollback

```bash
ssh deploy@VPS "cd /opt/apps/<name> && set -a && source /opt/infra/.env && set +a && TAG=<old-git-sha> docker compose up -d"
```
Or re-run the old workflow run from the GitHub Actions UI.

## Quarterly checklist

- `ssh deploy@VPS "cat /var/run/reboot-required 2>/dev/null; docker system prune -f; sudo zgrep 'Ban' /var/log/fail2ban.log* | tail"`
