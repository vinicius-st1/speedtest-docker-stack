#!/usr/bin/env bash
set -euo pipefail

STACK_ROOT="/opt/speedtest-docker-stack"
GEN="${STACK_ROOT}/generated"

echo "[apply] 1) Renderizando arquivos..."
python3 "${STACK_ROOT}/scripts/render.py"

echo "[apply] 2) Preparando diretórios..."
mkdir -p "${STACK_ROOT}/webroot" "${STACK_ROOT}/letsencrypt" "${STACK_ROOT}/data"

# Garantir diretórios de dados por instância
if [ -f "${GEN}/instances.txt" ]; then
  while read -r inst; do
    [ -z "${inst}" ] && continue
    mkdir -p "${STACK_ROOT}/data/${inst}"
    chown -R 10002:65534 "${STACK_ROOT}/data/${inst}" || true
  done < "${GEN}/instances.txt"
fi

echo "[apply] 3) Build das imagens (sequencial, sem corrida)..."
docker build -t st1/ookla-server:stable "${STACK_ROOT}/docker/ookla"
docker build -t st1/acme-nginx:stable "${STACK_ROOT}/docker/acme-nginx"

echo "[apply] 4) Subindo containers..."
docker compose --env-file "${GEN}/.env" -f "${GEN}/docker-compose.yml" up -d --remove-orphans

echo "[apply] 5) Status:"
docker compose --env-file "${GEN}/.env" -f "${GEN}/docker-compose.yml" ps
