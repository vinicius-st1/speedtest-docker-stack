#!/usr/bin/env bash
set -euo pipefail

# Bootstrap base de host Debian 12 para execução da stack speedtest em containers.
# Objetivo: aplicar pacotes, Docker oficial, sysctl e módulos de kernel de forma idempotente.

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERRO] execute como root (ex.: sudo bash scripts/bootstrap-host.sh)" >&2
  exit 1
fi

log() { echo "[bootstrap] $*"; }

SYSCTL_FILE="/etc/sysctl.d/99-speedtest-tuning.conf"
MODULES_FILE="/etc/modules-load.d/speedtest.conf"
DOCKER_KEYRING_DIR="/etc/apt/keyrings"
DOCKER_KEYRING="${DOCKER_KEYRING_DIR}/docker.gpg"
DOCKER_LIST="/etc/apt/sources.list.d/docker.list"

log "instalando pacotes utilitários base"
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  vim wget unzip net-tools psmisc curl ca-certificates gnupg lsb-release \
  git jq ripgrep python3 python3-yaml python3-jinja2 certbot

if [[ ! -f "${DOCKER_KEYRING}" ]]; then
  log "adicionando repositório oficial Docker"
  install -m 0755 -d "${DOCKER_KEYRING_DIR}"
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o "${DOCKER_KEYRING}"
  chmod a+r "${DOCKER_KEYRING}"
fi

if [[ ! -f "${DOCKER_LIST}" ]]; then
  log "escrevendo ${DOCKER_LIST}"
  cat > "${DOCKER_LIST}" <<DOCKERREPO
deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable
DOCKERREPO
fi

log "instalando Docker Engine e plugins"
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "habilitando Docker no boot"
systemctl enable --now docker

log "gravando tuning de kernel em ${SYSCTL_FILE}"
cat > "${SYSCTL_FILE}" <<'SYSCTL'
# speedtest-docker-stack tuning
# Mantém maior proporção de páginas em RAM para reduzir swap em carga de teste.
vm.swappiness = 5

# Reduz acúmulo de páginas sujas e estabiliza latência de I/O.
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5

# Escala de sockets e buffers de rede.
net.core.somaxconn = 65535
net.ipv4.tcp_mem = 4096 87380 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Otimizações TCP e controle de congestionamento.
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_max_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL

log "aplicando sysctl"
sysctl --system >/dev/null

log "configurando módulos de kernel em ${MODULES_FILE}"
cat > "${MODULES_FILE}" <<'MODULES'
tcp_illinois
tcp_westwood
tcp_htcp
MODULES

for module in tcp_illinois tcp_westwood tcp_htcp; do
  modprobe -a "${module}" || true
  log "módulo validado/carregado: ${module}"
done

log "bootstrap concluído"
log "valide com: docker --version && sysctl net.ipv4.tcp_congestion_control"
