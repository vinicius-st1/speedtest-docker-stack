#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GEN_DIR="${REPO_ROOT}/generated"
COMPOSE_FILE="${GEN_DIR}/docker-compose.yml"
ENV_FILE="${GEN_DIR}/.env"

if [ ! -f "${COMPOSE_FILE}" ] || [ ! -f "${ENV_FILE}" ]; then
  echo "[diagnose][ERRO] arquivos gerados ausentes. Execute primeiro: bash ${REPO_ROOT}/scripts/preflight.sh" >&2
  exit 1
fi

python3 - <<'PY'
from pathlib import Path
import yaml

inv = yaml.safe_load(Path('inventory.yml').read_text(encoding='utf-8')) or {}
instances = inv.get('instances', [])
project = (inv.get('global') or {}).get('project_name', 'speedtest-docker-stack')

print('[diagnose] Iniciando diagnóstico por instância...')
for inst in instances:
    name = inst.get('name')
    fqdn = inst.get('fqdn')
    ip4 = inst.get('ipv4')
    ip6 = inst.get('ipv6')
    if not all([name, fqdn, ip4, ip6]):
        continue
    print(f"\n===== {name} ({fqdn}) =====")
    print(f"Esperado IPv4: {ip4}")
    print(f"Esperado IPv6: {ip6}")
PY

while IFS= read -r inst; do
  [ -z "$inst" ] && continue
  project_name="$(python3 - <<'PY2'
from pathlib import Path
import yaml
inv = yaml.safe_load(Path('inventory.yml').read_text(encoding='utf-8')) or {}
print((inv.get('global') or {}).get('project_name', 'speedtest-docker-stack'))
PY2
)"
  acme_container="${project_name}_${inst}_acme"
  ookla_container="${project_name}_${inst}_ookla"

  echo "[diagnose] Containers da instância ${inst}:"
  docker ps --format 'table {{.Names}}\t{{.Status}}' | (grep -E "NAME|${inst}_(acme|ookla)" || true)

  fqdn="$(python3 - <<PY
from pathlib import Path
import yaml
inv = yaml.safe_load(Path('inventory.yml').read_text(encoding='utf-8')) or {}
for i in inv.get('instances', []):
  if i.get('name') == '${inst}':
    print(i.get('fqdn',''))
    break
PY
)"

  if [ -n "$fqdn" ]; then
    echo "[diagnose] DNS público e HTTP para ${fqdn}:"
    getent ahostsv4 "$fqdn" | awk '{print "A -> "$1}' | sort -u || true
    getent ahostsv6 "$fqdn" | awk '{print "AAAA -> "$1}' | sort -u || true
    curl -4 -sS -I "http://${fqdn}" | head -n 1 || true
  fi

  echo "[diagnose] Conectividade interna acme -> ookla (8080):"
  docker exec "$acme_container" sh -lc "wget -S -O - http://${inst}_ookla:8080 2>&1 | head -n 15" || true

  echo "[diagnose] Últimos logs acme/ookla (${inst}):"
  docker logs --tail=40 "$acme_container" || true
  docker logs --tail=40 "$ookla_container" || true

done < "${GEN_DIR}/instances.txt"

echo "[diagnose] fim"
