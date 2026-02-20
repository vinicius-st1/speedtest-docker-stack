#!/usr/bin/env bash
set -euo pipefail

STACK_ROOT="/opt/speedtest-docker-stack"
GEN="${STACK_ROOT}/generated"

# Garante que o ping existe
mkdir -p "${STACK_ROOT}/webroot/.well-known/acme-challenge"
echo "ok-$(date -Iseconds)" > "${STACK_ROOT}/webroot/.well-known/acme-challenge/ping.txt"

EMAIL="$(grep '^CERTBOT_EMAIL=' "${GEN}/.env" | cut -d= -f2-)"
if [ -z "${EMAIL}" ]; then
  echo "[certbot] ERRO: CERTBOT_EMAIL vazio."
  exit 2
fi

echo "[certbot] Emitindo certificados (1 por domínio)..."
python3 - <<'PY'
import yaml
from pathlib import Path
inv = yaml.safe_load(Path("/opt/speedtest-docker-stack/inventory.yml").read_text())
for i in inv["instances"]:
    print(i["fqdn"])
PY | while read -r fqdn; do
  [ -z "${fqdn}" ] && continue
  echo "==> ${fqdn}"
  docker compose --env-file "${GEN}/.env" -f "${GEN}/docker-compose.yml" run --rm certbot \
    certonly --webroot -w /var/www/certbot \
    --email "${EMAIL}" --agree-tos --no-eff-email \
    -d "${fqdn}"
done

echo
echo "[certbot] OK. Agora:"
echo "1) Edite /opt/speedtest-docker-stack/inventory.yml e coloque global.tls_enabled: true"
echo "2) Rode novamente: /opt/speedtest-docker-stack/scripts/apply.sh"
