#!/usr/bin/env bash
# Idempotent Wazuh host prep: sysctl, data dirs, certs, authd.pass.
# Run from /opt/infra/wazuh as deploy (sudo). Sourced .env must exist.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a && source .env && set +a

sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-wazuh.conf >/dev/null

sudo install -d -o deploy -g deploy /opt/data/wazuh /opt/data/wazuh/certs \
  /opt/data/wazuh/manager /opt/data/wazuh/dashboard-config /opt/data/wazuh/dashboard-custom
sudo install -d -o 1000 -g 1000 /opt/data/wazuh/indexer

if [ ! -f /opt/data/wazuh/certs/root-ca.pem ]; then
  docker compose -f generate-indexer-certs.yml run --rm generator
fi

# authd.pass is one line; 644 so the manager container can read it
umask 077
printf '%s\n' "${ENROLL_PASSWORD:?ENV_wazuh missing ENROLL_PASSWORD}" | sudo tee /opt/data/wazuh/authd.pass >/dev/null
sudo chmod 644 /opt/data/wazuh/authd.pass
