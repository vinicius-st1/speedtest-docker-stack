#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_ROOT="${REPO_ROOT}"
GEN="${STACK_ROOT}/generated"

python3 "${STACK_ROOT}/scripts/render.py"

mkdir -p "${STACK_ROOT}/webroot" "${STACK_ROOT}/letsencrypt" "${STACK_ROOT}/data"

if [ -f "${GEN}/instances.txt" ]; then
  while read -r inst; do
    [ -z "${inst}" ] && continue
    mkdir -p "${STACK_ROOT}/data/${inst}"
    chown -R 10002:65534 "${STACK_ROOT}/data/${inst}" || true
  done < "${GEN}/instances.txt"
fi

docker build -t st1/ookla-server:stable "${STACK_ROOT}/docker/ookla"
docker build -t st1/acme-nginx:stable "${STACK_ROOT}/docker/acme-nginx"

docker compose --env-file "${GEN}/.env" -f "${GEN}/docker-compose.yml" up -d --remove-orphans
docker compose --env-file "${GEN}/.env" -f "${GEN}/docker-compose.yml" ps
