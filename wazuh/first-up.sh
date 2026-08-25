#!/usr/bin/env bash
# Idempotent Wazuh host prep: sysctl, data dirs, certs, authd.pass, SAML config.
# Run from /opt/infra/wazuh as deploy (sudo). Sourced .env must exist.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a && source .env && set +a

: "${DOMAIN:?ENV_wazuh / DOMAIN missing DOMAIN}"
: "${SAML_EXCHANGE_KEY:?ENV_wazuh missing SAML_EXCHANGE_KEY}"
: "${ENROLL_PASSWORD:?ENV_wazuh missing ENROLL_PASSWORD}"

sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-wazuh.conf >/dev/null

sudo install -d -o deploy -g deploy /opt/data/wazuh /opt/data/wazuh/certs \
  /opt/data/wazuh/manager /opt/data/wazuh/dashboard-config /opt/data/wazuh/dashboard-custom \
  /opt/data/wazuh/indexer-security
sudo install -d -o 1000 -g 1000 /opt/data/wazuh/indexer

if [ ! -f /opt/data/wazuh/certs/root-ca.pem ]; then
  docker compose -f generate-indexer-certs.yml run --rm generator
fi

# authd.pass is one line; 644 so the manager container can read it
umask 077
printf '%s\n' "$ENROLL_PASSWORD" | sudo tee /opt/data/wazuh/authd.pass >/dev/null
sudo chmod 644 /opt/data/wazuh/authd.pass

# Expand DOMAIN + SAML_EXCHANGE_KEY only (template may contain other $ refs)
command -v envsubst >/dev/null || sudo apt-get install -yq gettext-base
export DOMAIN SAML_EXCHANGE_KEY
envsubst '$DOMAIN $SAML_EXCHANGE_KEY' < config/wazuh_indexer/config.yml.tmpl \
  | sudo tee /opt/data/wazuh/indexer-security/config.yml >/dev/null
sudo cp config/wazuh_indexer/roles_mapping.yml /opt/data/wazuh/indexer-security/roles_mapping.yml
sudo chmod 644 /opt/data/wazuh/indexer-security/config.yml \
  /opt/data/wazuh/indexer-security/roles_mapping.yml
