#!/usr/bin/env bash
set -euo pipefail

STACK_ROOT="/opt/speedtest-docker-stack"
WEBROOT="${STACK_ROOT}/webroot"

mkdir -p "${WEBROOT}/.well-known/acme-challenge"
echo "ok-$(date -Iseconds)" > "${WEBROOT}/.well-known/acme-challenge/ping.txt"

echo "[acme-smoke] Teste local (da VM) por FQDN:"
yq_installed=0
command -v yq >/dev/null 2>&1 && yq_installed=1 || true

if [ "${yq_installed}" -eq 0 ]; then
  echo "Instale yq para parsear YAML facilmente (opcional): apt-get install -y yq"
  echo "Ou teste manualmente: curl -v http://SEU_FQDN/.well-known/acme-challenge/ping.txt"
  exit 0
fi

for fqdn in $(yq -r '.instances[].fqdn' "${STACK_ROOT}/inventory.yml"); do
  echo "==> ${fqdn}"
  curl -fsS "http://${fqdn}/.well-known/acme-challenge/ping.txt" | tail -n 1
done
