#!/usr/bin/env bash
set -euo pipefail

# Diagnóstico rápido para 500/502 no frontend Nginx (acme) e backend Ookla.

STACK_ROOT="/opt/speedtest-docker-stack"
GEN_DIR="${STACK_ROOT}/generated"
COMPOSE_FILE="${GEN_DIR}/docker-compose.yml"
ENV_FILE="${GEN_DIR}/.env"
INSTANCES_FILE="${GEN_DIR}/instances.txt"

log() { echo "[diag] $*"; }
fail() { echo "[diag][ERRO] $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker não encontrado"
[ -f "${COMPOSE_FILE}" ] || fail "arquivo ausente: ${COMPOSE_FILE}"
[ -f "${ENV_FILE}" ] || fail "arquivo ausente: ${ENV_FILE}"
[ -f "${INSTANCES_FILE}" ] || fail "arquivo ausente: ${INSTANCES_FILE}"

PROJECT_NAME="$(grep -E '^COMPOSE_PROJECT_NAME=' "${ENV_FILE}" | head -n1 | cut -d'=' -f2-)"
[ -n "${PROJECT_NAME}" ] || fail "COMPOSE_PROJECT_NAME ausente em ${ENV_FILE}"

log "status geral da stack"
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" ps

while read -r inst; do
  [ -z "${inst}" ] && continue
  acme_ctr="${PROJECT_NAME}_${inst}_acme"
  ookla_ctr="${PROJECT_NAME}_${inst}_ookla"

  echo
  log "=== Instância: ${inst} ==="

  log "últimas linhas de log do acme"
  docker logs --tail=40 "${acme_ctr}" || true

  log "últimas linhas de log do ookla"
  docker logs --tail=60 "${ookla_ctr}" || true

  log "teste de resolução DNS interna do backend"
  docker exec "${acme_ctr}" getent hosts "${inst}_ookla" || true

  log "teste HTTP interno Nginx -> Ookla (8080)"
  docker exec "${acme_ctr}" sh -lc "wget -S -O - http://${inst}_ookla:8080 2>&1 | sed -n '1,20p'" || true

  log "teste HTTP local no próprio Nginx (localhost)"
  docker exec "${acme_ctr}" sh -lc "wget -S -O - http://127.0.0.1/ 2>&1 | sed -n '1,20p'" || true

  log "arquivo gerado de config Ookla (primeiras 60 linhas)"
  sed -n '1,60p' "${GEN_DIR}/config/${inst}/OoklaServer.properties" || true

done < "${INSTANCES_FILE}"

log "diagnóstico finalizado"
