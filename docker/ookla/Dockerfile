FROM debian:12-slim

SHELL ["/bin/bash", "-lc"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl tzdata procps iproute2 \
 && rm -rf /var/lib/apt/lists/*

# Usuário dedicado (boa prática)
RUN useradd -r -u 10002 -g nogroup -d /nonexistent -s /usr/sbin/nologin ookla \
 && mkdir -p /opt/ookla /opt/ookla/data \
 && chown -R 10002:65534 /opt/ookla

# Baixa o binário oficial (static-musl)
RUN curl -fsSL "https://install.speedtest.net/ooklaserver/stable/OoklaServer-linux-x86_64-static-musl.tgz" -o /tmp/ookla.tgz \
 && tar -xzf /tmp/ookla.tgz -C /opt/ookla \
 && rm -f /tmp/ookla.tgz \
 && chmod +x /opt/ookla/OoklaServer

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /opt/ookla

EXPOSE 8080 5060

ENTRYPOINT ["/entrypoint.sh"]
