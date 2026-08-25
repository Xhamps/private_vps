#!/usr/bin/env bash
# Install and enroll wazuh-agent 4.14.7 against localhost. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a && source .env && set +a

WAZUH_VER=4.14.7-1
if ! dpkg -s wazuh-agent >/dev/null 2>&1; then
  sudo install -d /usr/share/keyrings
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
  echo 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main' \
    | sudo tee /etc/apt/sources.list.d/wazuh.list >/dev/null
  sudo apt-get update -q
  sudo WAZUH_MANAGER=127.0.0.1 \
       WAZUH_REGISTRATION_PASSWORD="${ENROLL_PASSWORD:?}" \
       WAZUH_AGENT_NAME="$(hostname -s)" \
       apt-get install -y "wazuh-agent=${WAZUH_VER}"
  sudo apt-mark hold wazuh-agent
fi

# Ensure manager address is localhost even if the package was installed earlier
sudo sed -i 's#<address>.*</address>#<address>127.0.0.1</address>#' /var/ossec/etc/ossec.conf
sudo systemctl enable --now wazuh-agent
sudo systemctl restart wazuh-agent
