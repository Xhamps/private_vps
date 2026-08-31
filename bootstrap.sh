#!/usr/bin/env bash
# One-time server bootstrap (Phase 1). Idempotent — safe to re-run.
# Usage: scp bootstrap.sh root@VPS_IP:/tmp/ && ssh root@VPS_IP "bash /tmp/bootstrap.sh"
# Wazuh-only (CI, after /opt/infra/wazuh/.env exists):
#   sudo BOOTSTRAP_WAZUH_ONLY=1 bash /tmp/bootstrap.sh
set -euo pipefail

DEPLOY_USER=deploy
WAZUH_VER=4.14.7-1
WAZUH_DIR=/opt/infra/wazuh

bootstrap_wazuh() {
  echo "==> wazuh host prep"
  # Indexer needs this; persist so it survives reboot
  echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-wazuh.conf
  sysctl -w vm.max_map_count=262144 >/dev/null
  apt-get install -yq gettext-base

  install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/data/wazuh /opt/data/wazuh/certs \
    /opt/data/wazuh/manager /opt/data/wazuh/dashboard-config /opt/data/wazuh/dashboard-custom \
    /opt/data/wazuh/indexer-security
  install -d -o 1000 -g 1000 /opt/data/wazuh/indexer

  # Certs / authd / SAML need the stack .env + compose configs (after first deploy sync)
  if [ -f "$WAZUH_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a && source "$WAZUH_DIR/.env" && set +a
    : "${DOMAIN:?$WAZUH_DIR/.env missing DOMAIN}"
    : "${SAML_EXCHANGE_KEY:?$WAZUH_DIR/.env missing SAML_EXCHANGE_KEY}"
    : "${ENROLL_PASSWORD:?$WAZUH_DIR/.env missing ENROLL_PASSWORD}"

    if [ ! -f /opt/data/wazuh/certs/root-ca.pem ]; then
      (cd "$WAZUH_DIR" && docker compose -f generate-indexer-certs.yml run --rm generator)
    fi

    umask 077
    printf '%s\n' "$ENROLL_PASSWORD" > /opt/data/wazuh/authd.pass
    chmod 644 /opt/data/wazuh/authd.pass

    export DOMAIN SAML_EXCHANGE_KEY
    envsubst '$DOMAIN $SAML_EXCHANGE_KEY' < "$WAZUH_DIR/config/wazuh_indexer/config.yml.tmpl" \
      > /opt/data/wazuh/indexer-security/config.yml
    cp "$WAZUH_DIR/config/wazuh_indexer/roles_mapping.yml" \
      /opt/data/wazuh/indexer-security/roles_mapping.yml
    chmod 644 /opt/data/wazuh/indexer-security/config.yml \
      /opt/data/wazuh/indexer-security/roles_mapping.yml
  else
    echo "no $WAZUH_DIR/.env yet — skipping certs/SAML/authd (set ENV_wazuh and re-run, or let CI call BOOTSTRAP_WAZUH_ONLY=1)"
  fi

  echo "==> wazuh-agent"
  if ! dpkg -s wazuh-agent >/dev/null 2>&1; then
    install -d /usr/share/keyrings
    curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
    echo 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main' \
      > /etc/apt/sources.list.d/wazuh.list
    apt-get update -q
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
apt-get update -q
apt-get upgrade -yq
apt-get install -yq unattended-upgrades curl git rsync ufw fail2ban

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
echo "  secret   ENV_monitoring = GRAFANA_ADMIN_PASSWORD=<random>"
echo "  secret   ENV_wazuh      = see wazuh/.env.example"
echo "The pipeline writes the .env files on the VPS from these at every deploy."
