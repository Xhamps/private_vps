#!/usr/bin/env bash
# One-time server bootstrap (Phase 1). Idempotent — safe to re-run.
# Usage: scp bootstrap.sh root@VPS_IP:/tmp/ && ssh root@VPS_IP "bash /tmp/bootstrap.sh"
# Wazuh-only (CI): sudo BOOTSTRAP_WAZUH_ONLY=1 bash /tmp/bootstrap.sh
# Secrets from /opt/infra/wazuh/.env, or pass multiline ENV_WAZUH=... (and DOMAIN).
set -euo pipefail

DEPLOY_USER=deploy
WAZUH_VER=4.14.7-1
WAZUH_DIR=/opt/infra/wazuh
WAZUH_LIST=/etc/apt/sources.list.d/wazuh.list

# gpg --dearmor writes mode 600; apt's _apt user then can't read the keyring and
# every apt-get update fails with NO_PUBKEY 96B3EE5F29111145. Park a broken
# source before update, then reinstall the key world-readable (Wazuh docs).
park_wazuh_apt_list() {
  if [ -f "$WAZUH_LIST" ]; then
    mv -f "$WAZUH_LIST" "${WAZUH_LIST}.disabled"
  fi
}

ensure_wazuh_apt_repo() {
  apt-get install -yq curl gnupg
  install -d /usr/share/keyrings
  rm -f /usr/share/keyrings/wazuh.gpg
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
    | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
  chmod 644 /usr/share/keyrings/wazuh.gpg
  echo 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main' \
    > "$WAZUH_LIST"
  rm -f "${WAZUH_LIST}.disabled"
}

bootstrap_wazuh() {
  echo "==> wazuh host prep"
  # Indexer needs this; persist so it survives reboot
  echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-wazuh.conf
  sysctl -w vm.max_map_count=262144 >/dev/null

  park_wazuh_apt_list
  apt-get update -q
  apt-get install -yq gettext-base
  ensure_wazuh_apt_repo
  apt-get update -q

  install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/data/wazuh /opt/data/wazuh/certs \
    /opt/data/wazuh/manager /opt/data/wazuh/dashboard-config /opt/data/wazuh/dashboard-custom \
    /opt/data/wazuh/indexer-security
  install -d -o 1000 -g 1000 /opt/data/wazuh/indexer

  # Empty host bind-mounts hide image defaults (wazuh-docker #1167). Seed once from
  # the manager image; ownership must be root:wazuh (999), not the deploy user.
  mgr=/opt/data/wazuh/manager
  install -d "$mgr"/{api,etc,logs,queue,var,integrations,active-response,agentless,wodles,filebeat-etc,filebeat-var}

  seed_wazuh_manager_vol() {
    local dest=$1 src=$2 marker=${3:-}
    # Defaults live under data_tmp/permanent/ (see wazuh-docker 0-wazuh-init). Do not
    # docker run the stock entrypoint — s6 prints "starting Filebeat" to stdout and
    # breaks `tar | tar` pipes during CI bootstrap.
    local image_src="/var/ossec/data_tmp/permanent${src}"
    if [ -z "$(ls -A "$dest" 2>/dev/null || true)" ]; then
      echo "seeding $dest from $image_src"
      docker run --rm --entrypoint tar wazuh/wazuh-manager:4.14.7 \
        -C "$image_src" -cf - . | tar -C "$dest" -xf -
    elif [ -n "$marker" ] && [ ! -e "$dest/$marker" ]; then
      case "$marker" in
        shared/ar.conf)
          echo "creating missing $dest/$marker"
          install -d "$dest/shared"
          : > "$dest/shared/ar.conf"
          ;;
        api.yaml)
          echo "seeding partial $dest from $image_src"
          docker run --rm --entrypoint tar wazuh/wazuh-manager:4.14.7 \
            -C "$image_src" -cf - . | tar -C "$dest" -xf -
          ;;
      esac
    fi
  }

  # Partial host mounts skip container init's permanent-data copy; fill gaps without
  # overwriting existing files (cp -n).
  merge_wazuh_manager_vol() {
    local dest=$1 src=$2
    local image_src="/var/ossec/data_tmp/permanent${src}"
    echo "merging missing files into $dest"
    docker run --rm -v "$dest:/dest:rw" --entrypoint cp wazuh/wazuh-manager:4.14.7 \
      -rn "$image_src/." /dest/
  }

  seed_wazuh_manager_vol "$mgr/api" /var/ossec/api/configuration api.yaml
  merge_wazuh_manager_vol "$mgr/api" /var/ossec/api/configuration
  seed_wazuh_manager_vol "$mgr/etc" /var/ossec/etc shared/ar.conf
  merge_wazuh_manager_vol "$mgr/etc" /var/ossec/etc
  seed_wazuh_manager_vol "$mgr/logs" /var/ossec/logs
  merge_wazuh_manager_vol "$mgr/logs" /var/ossec/logs
  seed_wazuh_manager_vol "$mgr/queue" /var/ossec/queue
  merge_wazuh_manager_vol "$mgr/queue" /var/ossec/queue
  seed_wazuh_manager_vol "$mgr/var" /var/ossec/var/multigroups
  merge_wazuh_manager_vol "$mgr/var" /var/ossec/var/multigroups
  seed_wazuh_manager_vol "$mgr/integrations" /var/ossec/integrations
  merge_wazuh_manager_vol "$mgr/integrations" /var/ossec/integrations
  seed_wazuh_manager_vol "$mgr/active-response" /var/ossec/active-response/bin
  merge_wazuh_manager_vol "$mgr/active-response" /var/ossec/active-response/bin
  seed_wazuh_manager_vol "$mgr/agentless" /var/ossec/agentless
  merge_wazuh_manager_vol "$mgr/agentless" /var/ossec/agentless
  seed_wazuh_manager_vol "$mgr/wodles" /var/ossec/wodles
  merge_wazuh_manager_vol "$mgr/wodles" /var/ossec/wodles
  seed_wazuh_manager_vol "$mgr/filebeat-etc" /etc/filebeat
  merge_wazuh_manager_vol "$mgr/filebeat-etc" /etc/filebeat
  # /var/lib/filebeat is runtime state, not in PERMANENT_DATA — empty dir is fine.
  # Daemons run as wazuh (uid/gid 999). root-owned queue/db prevents wazuh-db from
  # creating the wdb socket (API error 1017, wazuh-db->failed).
  chown -R 999:999 "$mgr"

  for req in \
    "$mgr/api/api.yaml" \
    "$mgr/etc/shared/ar.conf" \
    "$mgr/etc/ossec.conf" \
    "$mgr/etc/lists/audit-keys"; do
    [ -e "$req" ] || {
      echo "wazuh manager seed incomplete: missing $req" >&2
      echo "remove /opt/data/wazuh/manager/* and re-run bootstrap (see docs/runbook.md)" >&2
      exit 1
    }
  done
  [ -d "$mgr/queue/db" ] || {
    echo "wazuh manager seed incomplete: missing $mgr/queue/db" >&2
    echo "remove /opt/data/wazuh/manager/queue and re-run bootstrap" >&2
    exit 1
  }

  # compose mounts dashboard-config/ over .../config/, hiding the wazuh.yml file bind.
  if [ -f "$WAZUH_DIR/config/wazuh_dashboard/wazuh.yml" ]; then
    install -m 644 "$WAZUH_DIR/config/wazuh_dashboard/wazuh.yml" \
      /opt/data/wazuh/dashboard-config/wazuh.yml
  fi

  # Certs / authd / SAML need DOMAIN + secrets from ENV_WAZUH (inline) or the stack .env
  if [ -n "${ENV_WAZUH:-}" ]; then
    # shellcheck disable=SC1091
    set -a && source <(printf '%s\n' "$ENV_WAZUH") && set +a
  elif [ -f "$WAZUH_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a && source "$WAZUH_DIR/.env" && set +a
  fi

  wazuh_need_secrets=0
  if [ "${BOOTSTRAP_WAZUH_ONLY:-}" = 1 ]; then
    wazuh_need_secrets=1
  fi

  if [ -n "${ENROLL_PASSWORD:-}" ] && [ -n "${SAML_EXCHANGE_KEY:-}" ] && [ -n "${DOMAIN:-}" ]; then
    : "${DOMAIN:?missing DOMAIN}"
    : "${SAML_EXCHANGE_KEY:?missing SAML_EXCHANGE_KEY}"
    : "${ENROLL_PASSWORD:?missing ENROLL_PASSWORD}"

    required_certs=(
      root-ca.pem
      wazuh.indexer.pem wazuh.indexer-key.pem
      wazuh.manager.pem wazuh.manager-key.pem
      wazuh.dashboard.pem wazuh.dashboard-key.pem
      admin.pem admin-key.pem
    )
    missing_certs=0
    for cert in "${required_certs[@]}"; do
      if [ ! -f "/opt/data/wazuh/certs/$cert" ]; then
        missing_certs=1
        break
      fi
    done
    if [ "$missing_certs" = 1 ]; then
      (cd "$WAZUH_DIR" && docker compose -f generate-indexer-certs.yml run --rm generator)
    fi
    for cert in "${required_certs[@]}"; do
      [ -f "/opt/data/wazuh/certs/$cert" ] || {
        echo "cert missing after generation: /opt/data/wazuh/certs/$cert" >&2
        exit 1
      }
    done

    # Compose bind-mounting a missing host path creates a directory and breaks authd.
    if [ -d /opt/data/wazuh/authd.pass ]; then
      echo "removing /opt/data/wazuh/authd.pass directory (stale compose mount)" >&2
      rm -rf /opt/data/wazuh/authd.pass
    fi
    umask 077
    printf '%s\n' "$ENROLL_PASSWORD" > /opt/data/wazuh/authd.pass
    chmod 644 /opt/data/wazuh/authd.pass

    for f in config.yml roles_mapping.yml; do
      if [ -d "/opt/data/wazuh/indexer-security/$f" ]; then
        echo "removing /opt/data/wazuh/indexer-security/$f directory (stale compose mount)" >&2
        rm -rf "/opt/data/wazuh/indexer-security/$f"
      fi
    done
    export DOMAIN SAML_EXCHANGE_KEY
    envsubst '$DOMAIN $SAML_EXCHANGE_KEY' < "$WAZUH_DIR/config/wazuh_indexer/config.yml.tmpl" \
      > /opt/data/wazuh/indexer-security/config.yml
    cp "$WAZUH_DIR/config/wazuh_indexer/roles_mapping.yml" \
      /opt/data/wazuh/indexer-security/roles_mapping.yml
    chmod 644 /opt/data/wazuh/indexer-security/config.yml \
      /opt/data/wazuh/indexer-security/roles_mapping.yml
  elif [ "$wazuh_need_secrets" = 1 ]; then
    echo "missing DOMAIN, ENROLL_PASSWORD, or SAML_EXCHANGE_KEY in $WAZUH_DIR/.env (or ENV_WAZUH)" >&2
    echo "ENV_wazuh must include all five keys — see wazuh/.env.example and docs/runbook.md" >&2
    exit 1
  else
    echo "no ENV_WAZUH / $WAZUH_DIR/.env (need DOMAIN, ENROLL_PASSWORD, SAML_EXCHANGE_KEY) — skipping certs/SAML/authd"
  fi

  echo "==> wazuh-agent"
  if ! dpkg -s wazuh-agent >/dev/null 2>&1; then
    # Enrollment password optional at first boot (manager may not be up yet)
    if [ -n "${ENROLL_PASSWORD:-}" ]; then
      WAZUH_MANAGER=127.0.0.1 \
        WAZUH_REGISTRATION_PASSWORD="$ENROLL_PASSWORD" \
        WAZUH_AGENT_NAME="$(hostname -s)" \
        apt-get install -y "wazuh-agent=${WAZUH_VER}"
    else
      WAZUH_MANAGER=127.0.0.1 \
        WAZUH_AGENT_NAME="$(hostname -s)" \
        apt-get install -y "wazuh-agent=${WAZUH_VER}"
    fi
    apt-mark hold wazuh-agent
  fi

  if [ -f /var/ossec/etc/ossec.conf ]; then
    sed -i 's#<address>.*</address>#<address>127.0.0.1</address>#' /var/ossec/etc/ossec.conf
  fi
  systemctl enable --now wazuh-agent
  systemctl restart wazuh-agent || true
}

if [ "${BOOTSTRAP_WAZUH_ONLY:-}" = 1 ]; then
  bootstrap_wazuh
  exit 0
fi

echo "==> apt packages"
export DEBIAN_FRONTEND=noninteractive
# Prior partial Wazuh setup leaves a signed-by repo whose keyring _apt cannot read.
park_wazuh_apt_list
apt-get update -q
apt-get upgrade -yq
apt-get install -yq unattended-upgrades curl git rsync ufw fail2ban gnupg

echo "==> deploy user"
if ! id "$DEPLOY_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
  usermod -aG sudo "$DEPLOY_USER"
fi
# passwordless sudo so CI can re-run this script; deploy is in the docker
# group anyway (root-equivalent), so this adds no real attack surface
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$DEPLOY_USER
chmod 440 /etc/sudoers.d/$DEPLOY_USER
# reuse root's authorized_keys (Hostinger installs your personal key there);
# append-only so re-runs never wipe keys added later (e.g. the CI key)
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /home/$DEPLOY_USER/.ssh
AUTH_KEYS=/home/$DEPLOY_USER/.ssh/authorized_keys
touch "$AUTH_KEYS"
if [ -f /root/.ssh/authorized_keys ]; then
  while IFS= read -r key; do
    grep -qxF "$key" "$AUTH_KEYS" || echo "$key" >> "$AUTH_KEYS"
  done < /root/.ssh/authorized_keys
fi
chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

echo "==> SSH hardening"
cat > /etc/ssh/sshd_config.d/hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF
systemctl reload ssh
echo "!!! TEST 'ssh $DEPLOY_USER@<ip>' IN A SECOND TERMINAL BEFORE CLOSING THIS SESSION !!!"

echo "==> ufw"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "==> fail2ban"
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
bantime = 1h
findtime = 10m
maxretry = 5
EOF
systemctl enable --now fail2ban
fail2ban-client status sshd || true

echo "==> docker"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker "$DEPLOY_USER"
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl enable --now docker
systemctl restart docker
docker network inspect proxy &>/dev/null || docker network create proxy

echo "==> directories"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/infra /opt/apps /opt/data
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/data/traefik
# data dirs must be writable by each container's internal user
install -d -o 65534 -g 65534 /opt/data/prometheus /opt/data/alertmanager  # nobody
install -d -o 472 -g 472 /opt/data/grafana                                # grafana
install -d /opt/data/uptime-kuma                                          # runs as root
install -d -o 10000 -g 10000 /opt/data/hermes                             # hermes agent
install -d -o 1000 -g 1000 /opt/data/n8n                                  # n8n (node user)

bootstrap_wazuh

echo "==> CI SSH keypair"
CI_KEY=/home/$DEPLOY_USER/.ssh/ci_ed25519
NEW_CI_KEY=0
# keyed on the .pub (kept forever); the private half is deleted after
# being saved to GitHub, and that must not trigger regeneration
if [ ! -f "${CI_KEY}.pub" ]; then
  sudo -u "$DEPLOY_USER" ssh-keygen -t ed25519 -N "" -C "github-actions-ci" -f "$CI_KEY"
  NEW_CI_KEY=1
fi
# ensure the CI pubkey is authorized even if a previous run dropped it
grep -qxF "$(cat "${CI_KEY}.pub")" "$AUTH_KEYS" || cat "${CI_KEY}.pub" >> "$AUTH_KEYS"

echo
if [ "$NEW_CI_KEY" = 1 ]; then
  # never print the private key (this output may land in CI logs)
  echo "================================================================"
  echo "NEW CI key generated. Retrieve it yourself (shown to no one else):"
  echo "  ssh $DEPLOY_USER@<ip> cat $CI_KEY"
  echo "Save it as the SSH_KEY secret in GitHub Actions"
  echo "(this repo + each project repo), along with:"
  echo "  SSH_HOST = $(curl -fsS -4 ifconfig.me || echo '<VPS IP>')"
  echo "  SSH_USER = $DEPLOY_USER"
  echo "Then delete it from the server: ssh $DEPLOY_USER@<ip> rm $CI_KEY"
  echo "================================================================"
fi
echo
echo "Also set in GitHub (Settings -> Secrets and variables -> Actions):"
echo "  variable DOMAIN         = yourdomain.com"
echo "  secret   ENV_monitoring = GRAFANA_ADMIN_PASSWORD=<openssl rand -hex 16>"
# Generate once here for ENV_wazuh; copy into the GitHub secret (plaintext).
# INDEXER/DASHBOARD/API demos must match vendored hashes until you rotate.
ENROLL_PASSWORD=$(openssl rand -hex 16)
SAML_EXCHANGE_KEY=$(openssl rand -hex 32)
echo "  secret   ENV_wazuh      = (multiline)"
echo "    INDEXER_PASSWORD=SecretPassword"
echo "    DASHBOARD_PASSWORD=kibanaserver"
echo "    API_PASSWORD=MyS3cr37P450r.*-"
echo "    ENROLL_PASSWORD=$ENROLL_PASSWORD"
echo "    SAML_EXCHANGE_KEY=$SAML_EXCHANGE_KEY"
echo "The pipeline writes the .env files on the VPS from these at every deploy."
