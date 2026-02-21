#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INV_FILE="${REPO_ROOT}/inventory.yml"
PRIV_FILE="${REPO_ROOT}/inventory.private.yml"

log() { echo "[preflight] $*"; }
fail() { echo "[preflight][ERRO] $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 não encontrado"
command -v docker >/dev/null 2>&1 || fail "docker não encontrado"

[ -f "${INV_FILE}" ] || fail "arquivo ausente: ${INV_FILE}"
[ -f "${PRIV_FILE}" ] || log "aviso: ${PRIV_FILE} ausente (seguindo apenas com inventory.yml)"

log "validando sintaxe do renderizador"
python3 -m py_compile "${REPO_ROOT}/scripts/render.py"

log "validando inventário e gerando artefatos"
python3 "${REPO_ROOT}/scripts/render.py"

PARENT_IFACE="$(python3 - <<'PY'
import yaml
from pathlib import Path
inv = yaml.safe_load(Path('inventory.yml').read_text())
print(inv.get('global', {}).get('parent_iface', ''))
PY
)"

if [ -n "${PARENT_IFACE}" ]; then
  ip link show "${PARENT_IFACE}" >/dev/null 2>&1 || fail "interface parent_iface inexistente no host: ${PARENT_IFACE}"
  log "interface parent_iface encontrada: ${PARENT_IFACE}"
fi

log "preflight concluído com sucesso"
