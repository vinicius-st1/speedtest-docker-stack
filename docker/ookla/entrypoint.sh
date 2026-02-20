#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ookla"
DATA_DIR="/opt/ookla/data"
PIDFILE="${DATA_DIR}/OoklaServer.pid"

cd "${APP_DIR}"

# Garantir permissões no volume persistente
chown -R 10002:65534 "${DATA_DIR}" || true

# Remover pidfile "fantasma"
if [ -f "${PIDFILE}" ]; then
  if ! kill -0 "$(cat "${PIDFILE}")" >/dev/null 2>&1; then
    rm -f "${PIDFILE}"
  fi
fi

echo "[ookla] Iniciando OoklaServer em modo daemon com pidfile..."
# Forma correta (sem daemon=false). Exemplo real de uso: --daemon --pidfile=... :contentReference[oaicite:4]{index=4}
"${APP_DIR}/OoklaServer" --daemon --pidfile="${PIDFILE}"

# Aguarda o pid subir
for i in {1..30}; do
  if [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" >/dev/null 2>&1; then
    echo "[ookla] OK: PID $(cat "${PIDFILE}")"
    break
  fi
  sleep 1
done

if [ ! -f "${PIDFILE}" ] || ! kill -0 "$(cat "${PIDFILE}")" >/dev/null 2>&1; then
  echo "[ookla] ERRO: OoklaServer não iniciou corretamente."
  exit 1
fi

# Monitor: se o processo morrer, derruba o container (para o restart do Docker)
trap 'echo "[ookla] Recebi sinal, encerrando..."; if [ -f "${PIDFILE}" ]; then kill "$(cat "${PIDFILE}")" || true; fi; exit 0' SIGTERM SIGINT

while true; do
  if ! kill -0 "$(cat "${PIDFILE}")" >/dev/null 2>&1; then
    echo "[ookla] ERRO: processo morreu, saindo para restart."
    exit 1
  fi
  sleep 5
done
