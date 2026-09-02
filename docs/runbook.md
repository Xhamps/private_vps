# Runbook

## First deploy (order matters)

1. Phase 0 done (VPS + DNS wildcard + SSH key).
2. `scp bootstrap.sh root@VPS_IP:/tmp/ && ssh root@VPS_IP "bash /tmp/bootstrap.sh"` — it generates a CI keypair and prints instructions (never the key itself). Fetch the private key over SSH, save it as the `SSH_KEY` secret (plus `SSH_HOST`, `SSH_USER`), then delete it from the VPS. At the end it also prints a ready-to-paste multiline `ENV_wazuh` block (`ENROLL_PASSWORD` / `SAML_EXCHANGE_KEY` are generated there).
3. In GitHub → Settings → Secrets and variables → Actions (org-level where shared):
   - **Variable** `DOMAIN` = `yourdomain.com` (this repo + every project repo)
   - **Secret** `ENV_monitoring` = `GRAFANA_ADMIN_PASSWORD=<openssl rand -hex 16>`
   - **Secret** `ENV_wazuh` — copy the multiline block from the bootstrap output (or wait until the Wazuh stack; see [Wazuh](#wazuh))
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

## Wazuh

`ENV_wazuh` is **plaintext** only. The indexer does **not** read passwords from `.env` for `admin` / `kibanaserver` — those live as bcrypt hashes in `wazuh/config/wazuh_indexer/internal_users.yml` (rsynced, bind-mounted). No `envsubst` on that file. Compose uses the plaintext so manager/dashboard can talk to the indexer; both sides must match.

1. GitHub secret `ENV_wazuh` — prefer the multiline block printed at the end of `bootstrap.sh`. Shape (also in `wazuh/.env.example`):
   ```
   INDEXER_PASSWORD=SecretPassword
   DASHBOARD_PASSWORD=kibanaserver
   API_PASSWORD=MyS3cr37P450r.*-
   ENROLL_PASSWORD=<from bootstrap output>
   SAML_EXCHANGE_KEY=<from bootstrap output>
   ```
   Bootstrap generates `ENROLL_PASSWORD` (`openssl rand -hex 16`) and `SAML_EXCHANGE_KEY` (`openssl rand -hex 32`). Copy that run’s values once into the GitHub secret — do not re-run bootstrap just to refresh them unless you intend to rotate.

   Demo indexer/dashboard/API values are fine **only while** they match git:
   - `INDEXER_PASSWORD=SecretPassword` → must match `admin.hash` in `internal_users.yml`
   - `DASHBOARD_PASSWORD=kibanaserver` → must match `kibanaserver.hash` in `internal_users.yml`
   - `API_PASSWORD=MyS3cr37P450r.*-` → must match plain text in `wazuh.yml` (no bcrypt)
   After rotating hashes in `internal_users.yml`, update `ENV_wazuh` to the matching plaintext (see below).

2. Deploy: push `wazuh/` (or `workflow_dispatch` stack `wazuh`). CI syncs configs, writes `.env` from `ENV_wazuh` + `DOMAIN`, runs `bootstrap.sh` with `BOOTSTRAP_WAZUH_ONLY=1` (reads `/opt/infra/wazuh/.env`, or an inline `ENV_WAZUH=...` env if you pass it), then compose up, then bootstrap again so the agent can enroll once the manager is up. Re-run full `bootstrap.sh` anytime to refresh host prep. The separate `.github/workflows/bootstrap.yml` (manual full host bootstrap) does **not** replace the deploy-time Wazuh host-prep step.

3. Keycloak (`XhampsHub` realm) — SAML client (manual once):
   - Client type: SAML · Client ID: `wazuh-saml`
   - Valid redirect URIs: `https://wazuh.<domain>/*`
   - IDP-Initiated SSO URL name: `wazuh-dashboard`
   - Client signature required: Off
   - ACS POST Binding URL: `https://wazuh.<domain>/_opendistro/_security/saml/acs/idpinitiated`
   - Logout Service Redirect Binding URL: `https://wazuh.<domain>`
   - Realm role `wazuh-admins` on a group; on client scope `role_list` add mapper Role attribute name `Roles`, Single Role Attribute On
4. After first SSO login: Dashboard → Server management → Security → Roles mapping → `backend_roles` FIND `wazuh-admins` → role `administrator`. Break-glass: `admin` / `INDEXER_PASSWORD`.
5. Uptime Kuma: HTTPS check for `https://wazuh.<domain>`.
6. Verify:
   ```bash
   ssh deploy@VPS 'docker compose -f /opt/infra/wazuh/docker-compose.yml ps'
   ssh deploy@VPS 'docker compose -f /opt/infra/wazuh/docker-compose.yml exec wazuh.manager /var/ossec/bin/wazuh-control status'
   ssh deploy@VPS 'systemctl is-active wazuh-agent'
   ssh deploy@VPS 'ss -lntp | grep -E "1514|1515"'   # must be 127.0.0.1 only
   curl -sI "https://wazuh.$DOMAIN" | head
   ```
   Agents → Summary should show this host connected.

   The manager runs **inside Docker** (`wazuh.manager`), not as host `wazuh-manager.service`. Only **`wazuh-agent`** is a native systemd unit on this VPS.

### Rotate indexer / dashboard passwords

1. Generate plaintext and bcrypt hashes (Wazuh 4.14.7 image):
   ```bash
   INDEXER_PASSWORD=$(openssl rand -base64 24)
   DASHBOARD_PASSWORD=$(openssl rand -base64 24)

   docker run --rm wazuh/wazuh-indexer:4.14.7 bash -lc \
     'export JAVA_HOME=/usr/share/wazuh-indexer/jdk
      /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "'"$INDEXER_PASSWORD"'"'

   docker run --rm wazuh/wazuh-indexer:4.14.7 bash -lc \
     'export JAVA_HOME=/usr/share/wazuh-indexer/jdk
      /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "'"$DASHBOARD_PASSWORD"'"'
   ```
2. Put plaintext in GitHub `ENV_wazuh`. Put hashes in git: `admin.hash` ← indexer, `kibanaserver.hash` ← dashboard.
3. Push / redeploy `wazuh`. If the indexer was already initialized, apply security config once (below) so the new hashes load.

`API_PASSWORD`: change plaintext in both `ENV_wazuh` and `wazuh/config/wazuh_dashboard/wazuh.yml` (no hash).

`ENROLL_PASSWORD` / `SAML_EXCHANGE_KEY`: plaintext in `ENV_wazuh` only (or generate fresh with `openssl rand -hex 16` / `openssl rand -hex 32`). On the next Wazuh deploy, bootstrap rewrites `authd.pass` and the SAML config from `.env` (or from `ENV_WAZUH` if you pass that instead).

### Manager unhealthy (`dependency wazuh.manager failed to start`)

The dashboard waits on `wazuh.manager` passing `wazuh-control status` (every daemon running). On the VPS:

```bash
ssh deploy@VPS 'docker compose -f /opt/infra/wazuh/docker-compose.yml logs wazuh.manager --tail 80'
ssh deploy@VPS 'docker compose -f /opt/infra/wazuh/docker-compose.yml exec wazuh.manager /var/ossec/bin/wazuh-control status'
```

Check these in order:

1. **`ENV_wazuh` incomplete** — GitHub secret must include all five keys (`INDEXER_PASSWORD`, `DASHBOARD_PASSWORD`, `API_PASSWORD`, `ENROLL_PASSWORD`, `SAML_EXCHANGE_KEY`). If bootstrap skipped host prep, redeploy after fixing the secret. Bootstrap now fails the deploy instead of continuing silently.

2. **`authd.pass` is a directory** — happens if compose ran before bootstrap created the file:
   ```bash
   ssh deploy@VPS 'file /opt/data/wazuh/authd.pass; ls -la /opt/data/wazuh/authd.pass'
   ```
   If it says “directory”, remove it and redeploy: `sudo rm -rf /opt/data/wazuh/authd.pass`, then re-run the wazuh workflow.

3. **Password mismatch** — `INDEXER_PASSWORD` in `ENV_wazuh` must match `admin.hash` in `internal_users.yml` (demo: `SecretPassword`). Until you rotate hashes in git, use the demo values from `wazuh/.env.example`.

4. **Empty manager bind-mounts** — empty `/opt/data/wazuh/manager/*` dirs hide image defaults. Symptoms:
   - `(1103): Could not open file 'etc/shared/ar.conf'` — `wazuh-apid` never starts
   - `api.log`: `unable to open database file` during API migration — same root cause on `manager/api`
   ```bash
   ssh deploy@VPS 'sudo BOOTSTRAP_WAZUH_ONLY=1 bash /tmp/bootstrap.sh'
   ssh deploy@VPS 'cd /opt/infra/wazuh && docker compose up -d --force-recreate wazuh.manager'
   ssh deploy@VPS 'docker compose -f /opt/infra/wazuh/docker-compose.yml exec wazuh.manager /var/ossec/bin/wazuh-control status'
   ```
   Bootstrap seeds all manager data dirs from the image when empty and sets ownership to `root:wazuh` (999).

5. **Missing or partial certs** — `ls /opt/data/wazuh/certs/` should list `root-ca.pem`, `wazuh.manager.pem`, `wazuh.manager-key.pem`, etc. Redeploy (bootstrap regenerates if any are missing).

6. **Slow first boot / low RAM** — first start can take several minutes (ruleset + vulnerability feeds). Manager healthcheck allows 180s + retries; if `wazuh-control status` shows daemons still starting, wait and `docker compose up -d` again. Check OOM: `dmesg | tail | grep -i kill`.

After fixing host state: Actions → **deploy-infra** → **Run workflow** → stack `wazuh`.

### CI shows `client_loop: send disconnect: Broken pipe`

That is the **SSH session** dropping, not a Wazuh container error. It happened when Compose blocked waiting for `wazuh.manager` to pass its healthcheck (first boot can take several minutes). The deploy workflow now starts the dashboard after the manager **container** is up (not after every daemon is healthy) and polls before agent enroll.

If a run still dies mid-SSH, check the VPS — the stack may have kept starting:

```bash
ssh deploy@VPS 'docker compose -f /opt/infra/wazuh/docker-compose.yml ps'
```

Re-run workflow stack `wazuh` if manager or dashboard is still unhealthy.

### Apply indexer security config (SAML or password rotation)

Needed if SSO was missing after first boot (indexer initialized without SAML), or after changing `internal_users.yml` hashes on a live indexer:

```bash
ssh deploy@VPS 'cd /opt/infra/wazuh && docker compose exec wazuh.indexer bash -c "
  export JAVA_HOME=/usr/share/wazuh-indexer/jdk
  bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
    -cd /usr/share/wazuh-indexer/config/opensearch-security \
    -icl -nhnv \
    -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem \
    -cert /usr/share/wazuh-indexer/config/certs/admin.pem \
    -key /usr/share/wazuh-indexer/config/certs/admin-key.pem \
    -h wazuh.indexer
"'
```

## Rollback

```bash
ssh deploy@VPS "cd /opt/apps/<name> && TAG=<old-git-sha> docker compose up -d"   # shell env overrides the .env TAG
```
Or re-run the old workflow run from the GitHub Actions UI. For Wazuh: `workflow_dispatch` stack `wazuh` on a previous SHA; `docker compose down` does not uninstall `wazuh-agent`.

## Quarterly checklist

- `ssh deploy@VPS "cat /var/run/reboot-required 2>/dev/null; docker system prune -f; sudo zgrep 'Ban' /var/log/fail2ban.log* | tail"`
