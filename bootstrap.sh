#!/usr/bin/env bash
# One-time server bootstrap (Phase 1). Idempotent — safe to re-run.
# Usage: scp bootstrap.sh root@VPS_IP:/tmp/ && ssh root@VPS_IP "bash /tmp/bootstrap.sh"
set -euo pipefail

DEPLOY_USER=deploy

echo "==> apt packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -yq
apt-get install -yq unattended-upgrades curl git rsync ufw fail2ban jq

echo "==> deploy user"
if ! id "$DEPLOY_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
  usermod -aG sudo "$DEPLOY_USER"
fi
# passwordless sudo so CI can re-run this script; deploy is in the docker
# group anyway (root-equivalent), so this adds no real attack surface
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$DEPLOY_USER
chmod 440 /etc/sudoers.d/$DEPLOY_USER
# reuse root's authorized_keys (Hostinger installs your personal key there)
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /home/$DEPLOY_USER/.ssh
if [ -f /root/.ssh/authorized_keys ]; then
  cp /root/.ssh/authorized_keys /home/$DEPLOY_USER/.ssh/authorized_keys
  chown "$DEPLOY_USER:$DEPLOY_USER" /home/$DEPLOY_USER/.ssh/authorized_keys
  chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys
fi

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
# never ban GitHub Actions runners; list refreshed on every bootstrap run
GH_IPS=$(curl -fsS https://api.github.com/meta | jq -r '.actions[]' | tr '\n' ' ')
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 $GH_IPS

[sshd]
enabled = true
bantime = 1h
findtime = 10m
maxretry = 5
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban
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

echo "==> CI SSH keypair"
CI_KEY=/home/$DEPLOY_USER/.ssh/ci_ed25519
if [ ! -f "$CI_KEY" ]; then
  sudo -u "$DEPLOY_USER" ssh-keygen -t ed25519 -N "" -C "github-actions-ci" -f "$CI_KEY"
  cat "${CI_KEY}.pub" >> /home/$DEPLOY_USER/.ssh/authorized_keys
fi

echo
echo "================================================================"
echo "Add these GitHub Actions secrets (this repo + each project repo):"
echo "  SSH_HOST = $(curl -fsS -4 ifconfig.me || echo '<VPS IP>')"
echo "  SSH_USER = $DEPLOY_USER"
echo "  SSH_KEY  = (private key below — shown once, then delete it here)"
echo "================================================================"
cat "$CI_KEY"
echo "================================================================"
echo "After copying, run: ssh $DEPLOY_USER@<ip> 'rm ~/.ssh/ci_ed25519'"
echo
echo "Also set in GitHub (Settings -> Secrets and variables -> Actions):"
echo "  variable DOMAIN         = yourdomain.com"
echo "  secret   ENV_monitoring = GRAFANA_ADMIN_PASSWORD=<random>"
echo "The pipeline writes the .env files on the VPS from these at every deploy."
