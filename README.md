# speedtest-docker-stack

Guia operacional **detalhado** para provisionar medidores Ookla em Debian 12 com Docker, usando uma arquitetura escalável por instância:

- 1 IPv4 público dedicado por medidor (uso de /32 por instância)
- 1 IPv6 público dedicado por medidor (uso de /128 por instância)
- Host com rede privada de gerenciamento separada
- Publicação de serviços por containers com rede `ipvlan` L3

Repositório oficial: `https://github.com/vinicius-st1/speedtest-docker-stack.git`  
Diretório operacional padrão: `/opt/speedtest-docker-stack`

---

## Visão geral da arquitetura

Este repositório automatiza a geração de arquivos e o deploy da stack com base em inventário declarativo.

### Arquivos-chave do projeto

- `/opt/speedtest-docker-stack/inventory.yml`  
  Inventário principal (versionado), com parâmetros globais e lista de instâncias.
- `/opt/speedtest-docker-stack/inventory.private.yml`  
  Inventário privado (não versionado), para dados sensíveis (ex.: `properties_raw` do Ookla).
- `/opt/speedtest-docker-stack/scripts/render.py`  
  Renderiza templates e valida chaves obrigatórias.
- `/opt/speedtest-docker-stack/scripts/preflight.sh`  
  Validação pré-deploy (inventário, sintaxe, interface de rede e geração dos arquivos).
- `/opt/speedtest-docker-stack/scripts/apply.sh`  
  Pipeline de aplicação (preflight + diretórios + build + compose up).
- `/opt/speedtest-docker-stack/scripts/diagnose.sh`  
  Diagnóstico pós-deploy para erros HTTP 502, DNS e backend Ookla por instância.
- `/opt/speedtest-docker-stack/templates/docker-compose.yml.j2`  
  Modelo dos serviços e rede pública `ipvlan` L3.

---

## Passo 0 — Implementação do zero (ordem exata na VM)

Use este bloco como **runbook objetivo** na VM Debian 12 (`10.4.18.202/26`), do zero até validação final:

1. Preparar SO e instalar Docker.
2. Clonar o projeto em `/opt/speedtest-docker-stack`.
3. Instalar dependências Python (APT ou `venv`).
4. Preencher `inventory.yml` + `inventory.private.yml` com seus 4 medidores.
5. Executar preflight (`scripts/preflight.sh`).
6. Aplicar stack (`scripts/apply.sh`).
7. Validar `docker compose ps`, `curl -I` e logs por instância.
8. Corrigir 502 (se houver) com diagnóstico da seção 10.3.1.
9. Habilitar TLS somente após HTTP estável.

### Checklist rápido (copiar e colar)

```bash
# 1) Base do sistema
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl ca-certificates gnupg lsb-release python3 python3-pip python3-venv jq

# 2) Docker oficial
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker

# 3) Projeto
sudo mkdir -p /opt && cd /opt
sudo git clone https://github.com/vinicius-st1/speedtest-docker-stack.git
sudo chown -R "$USER":"$USER" /opt/speedtest-docker-stack
cd /opt/speedtest-docker-stack

# 4) Dependências Python (Debian 12 / PEP668)
sudo apt install -y python3-yaml python3-jinja2

# 5) Inventário privado
cp /opt/speedtest-docker-stack/inventory.private.yml.example /opt/speedtest-docker-stack/inventory.private.yml

# 6) Pré-validação + deploy
bash /opt/speedtest-docker-stack/scripts/preflight.sh
bash /opt/speedtest-docker-stack/scripts/apply.sh

# 7) Validação pós-deploy
docker compose --env-file /opt/speedtest-docker-stack/generated/.env -f /opt/speedtest-docker-stack/generated/docker-compose.yml ps
curl -I http://speedtest01.st1internet.com.br
curl -I http://speedtest02.st1internet.com.br
curl -I http://speedtest03.st1internet.com.br
curl -I http://speedtest04.st1internet.com.br

# Se houver 502 em qualquer instância
bash /opt/speedtest-docker-stack/scripts/diagnose.sh
```

---

## Passo 1 — Preparar o host Debian 12

> Objetivo: garantir base estável e reproduzível para operação de containers.

Atualize pacotes do sistema:

```bash
sudo apt update
sudo apt upgrade -y
```

Instale utilitários essenciais:

```bash
sudo apt install -y \
  git curl ca-certificates gnupg lsb-release \
  python3 python3-pip python3-venv jq
```

**Boa prática aplicada:** padronizar ferramentas mínimas (`jq`, `python3`, `git`) para facilitar troubleshooting e automação.

---

## Passo 2 — Instalar Docker Engine (repositório oficial)

> Objetivo: usar versão atual e suportada do Docker + Compose Plugin.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

Validação rápida:

```bash
docker --version
docker compose version
sudo systemctl status docker --no-pager
```

---

## Passo 3 — Clonar o repositório no caminho padrão

```bash
sudo mkdir -p /opt
cd /opt
sudo git clone https://github.com/vinicius-st1/speedtest-docker-stack.git
sudo chown -R "$USER":"$USER" /opt/speedtest-docker-stack
cd /opt/speedtest-docker-stack
```

---

## Passo 4 — Instalar dependências Python do renderizador

Arquivo envolvido: `/opt/speedtest-docker-stack/scripts/render.py`

Em Debian 12, por padrão há proteção PEP 668 (erro `externally-managed-environment`).
Por isso, use **uma das opções abaixo** (não recomendado forçar `--break-system-packages`).

### Opção A (recomendada para servidor Debian): pacotes APT

```bash
sudo apt update
sudo apt install -y python3-yaml python3-jinja2
```

### Opção B (recomendada para isolamento): virtualenv local do projeto

```bash
cd /opt/speedtest-docker-stack
sudo apt install -y python3-venv
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install pyyaml jinja2
```

Validação rápida das bibliotecas:

```bash
python3 -c "import yaml, jinja2; print('ok')"
```

**Por quê:** sem `pyyaml` e `jinja2`, a renderização do inventário não executa. Em Debian 12, prefira APT ou `venv` para seguir boas práticas do sistema.

---

## Passo 5 — Entender requisito de rede antes do deploy

A stack usa `ipvlan` modo `l3`. Isso exige coerência entre host, upstream e DNS.

### 5.1 Requisitos de conectividade

1. O host Debian precisa ter conectividade de saída pela rede de gerenciamento privada.
2. O upstream/provedor precisa rotear os IPs públicos de cada medidor para o host Debian.
3. DNS de cada FQDN deve apontar para o IPv4/IPv6 da instância correspondente.

### 5.2 Checklist de rede no host

```bash
ip -br a
ip r
ip -6 r
```

Se o retorno de rota não estiver correto no upstream, o container sobe, mas não recebe tráfego externo.


### 5.3 Topologia deste cenário (informações fornecidas)

- **VM Debian (gerência):** `10.4.18.202/26`
- **Speedtest 01:** `speedtest01.st1internet.com.br` → `45.179.238.59` / `2804:60d4:45:179:238::59`
- **Speedtest 02:** `speedtest02.st1internet.com.br` → `45.179.238.60` / `2804:60d4:45:179:238::60`
- **Speedtest 03:** `speedtest03.st1internet.com.br` → `45.179.238.61` / `2804:60d4:45:179:238::61`
- **Speedtest 04:** `speedtest04.st1internet.com.br` → `45.179.238.62` / `2804:60d4:45:179:238::62`

> Observação importante: na informação inicial havia duplicidade de DNS para o item 02 (`speedtest01...`).
> Para evitar conflito de certificado, cache DNS e roteamento HTTP/TLS, o FQDN correto da instância 02 deve ser `speedtest02.st1internet.com.br`.

---

## Passo 6 — Configurar inventário principal

Arquivo: `/opt/speedtest-docker-stack/inventory.yml`

Preencha obrigatoriamente:

- `global.project_name`
- `global.stack_root`
- `global.parent_iface`
- `global.public_subnet_ipv4`
- `global.public_subnet_ipv6`
- `global.tls_enabled`
- `global.certbot_email`
- Em cada `instances[]`: `name`, `fqdn`, `ipv4`, `ipv6`

### Exemplo completo de arquivo

**Arquivo:** `/opt/speedtest-docker-stack/inventory.yml`

```yaml
global:
  project_name: "speedtest-docker-stack"
  stack_root: "/opt/speedtest-docker-stack"
  parent_iface: "ens192"
  public_subnet_ipv4: "45.179.238.0/24"
  public_subnet_ipv6: "2804:60d4:0045:0179::/64"
  tls_enabled: false
  certbot_email: "noc@st1.net.br"

instances:
  - name: "speedtest01"
    fqdn: "speedtest01.st1internet.com.br"
    ipv4: "45.179.238.59"
    ipv6: "2804:60D4:45:179:238::59"

  - name: "speedtest02"
    fqdn: "speedtest02.st1internet.com.br"
    ipv4: "45.179.238.60"
    ipv6: "2804:60D4:45:179:238::60"
```

---

## Passo 7 — Configurar inventário privado

Arquivo de exemplo: `/opt/speedtest-docker-stack/inventory.private.yml.example`  
Arquivo final: `/opt/speedtest-docker-stack/inventory.private.yml`

Crie o arquivo privado:

```bash
cp /opt/speedtest-docker-stack/inventory.private.yml.example /opt/speedtest-docker-stack/inventory.private.yml
```

Use este arquivo para dados sensíveis e blocos `properties_raw` de cada instância.

> `ookla.properties_raw` é obrigatório por instância. Sem ele, o preflight falha para evitar deploy inconsistente (causa comum de `502 Bad Gateway`).

### Exemplo completo de arquivo

**Arquivo:** `/opt/speedtest-docker-stack/inventory.private.yml`

```yaml
instances:
  - name: "speedtest01"
    ookla:
      properties_raw: |
        # Exemplo fictício
        # key=value

  - name: "speedtest02"
    ookla:
      properties_raw: |
        # Exemplo fictício
        # key=value
```

**Boa prática aplicada:** manter segredo fora do inventário versionado para reduzir risco de exposição.

---

## Passo 8 — Executar preflight (validação automática antes do deploy)

```bash
cd /opt/speedtest-docker-stack
bash /opt/speedtest-docker-stack/scripts/preflight.sh
```

O preflight executa:

1. Verificação de binários obrigatórios (`python3`, `docker`).
2. Validação sintática do `scripts/render.py`.
3. Validação avançada do inventário (`inventory.yml` + `inventory.private.yml`), incluindo:
   - duplicidade de `name`, `fqdn`, `ipv4`, `ipv6`;
   - consistência de IPs dentro de `public_subnet_ipv4` e `public_subnet_ipv6`.
4. Geração de artefatos em `/opt/speedtest-docker-stack/generated`.
5. Verificação da existência da interface `parent_iface` no host.

Arquivos esperados após preflight:

- `/opt/speedtest-docker-stack/generated/.env`
- `/opt/speedtest-docker-stack/generated/docker-compose.yml`
- `/opt/speedtest-docker-stack/generated/instances.txt`
- `/opt/speedtest-docker-stack/generated/config/<instancia>/nginx.conf`
- `/opt/speedtest-docker-stack/generated/config/<instancia>/OoklaServer.properties`

Valide:

```bash
cat /opt/speedtest-docker-stack/generated/instances.txt
```

---

## Passo 9 — Aplicar stack completa

Arquivo: `/opt/speedtest-docker-stack/scripts/apply.sh`

```bash
bash /opt/speedtest-docker-stack/scripts/apply.sh
```

Esse script executa, em ordem:

1. Execução do preflight (`scripts/preflight.sh`, que já renderiza e valida inventário)
2. Criação de persistência (`webroot`, `letsencrypt`, `data`)
3. Ajuste de owner para dados Ookla
4. Build das imagens locais (`st1/ookla-server:stable`, `st1/acme-nginx:stable`)
5. `docker compose up -d --remove-orphans`

---

## Passo 10 — Validação pós-deploy (obrigatória)

### 10.1 Estado dos serviços

```bash
docker compose --env-file /opt/speedtest-docker-stack/generated/.env \
  -f /opt/speedtest-docker-stack/generated/docker-compose.yml ps
```

### 10.2 Endereçamento das instâncias

```bash
docker inspect speedtest-docker-stack_speedtest01_acme \
  --format '{{json .NetworkSettings.Networks}}' | jq
```

### 10.3 Teste HTTP por FQDN

```bash
curl -I http://speedtest01.st1internet.com.br
```

Se retornar `HTTP/1.1 502 Bad Gateway`, significa que o Nginx do container `_acme` está ativo, mas não conseguiu alcançar o backend Ookla (`<instancia>_ookla:8080` ou `:5060`).

### 10.3.1 Diagnóstico rápido para erro 502

1. Confirmar se os dois containers da instância estão em execução:

```bash
docker ps --format 'table {{.Names}}	{{.Status}}' | grep speedtest01
```

2. Validar resolução DNS interna entre containers (nome do serviço):

```bash
docker exec -it speedtest-docker-stack_speedtest01_acme getent hosts speedtest01_ookla
```

3. Testar conectividade do Nginx para o backend Ookla:

```bash
docker exec -it speedtest-docker-stack_speedtest01_acme sh -lc 'wget -S -O - http://speedtest01_ookla:8080 2>&1 | head -n 20'
```

4. Verificar logs dos dois containers para identificar causa raiz:

```bash
docker logs --tail=200 speedtest-docker-stack_speedtest01_acme
docker logs --tail=200 speedtest-docker-stack_speedtest01_ookla
```

5. Validar se o arquivo de configuração da instância foi gerado corretamente:

```bash
cat /opt/speedtest-docker-stack/generated/config/speedtest01/nginx.conf
cat /opt/speedtest-docker-stack/generated/config/speedtest01/OoklaServer.properties
```

6. Reaplicar stack após correções de inventário/properties:

```bash
bash /opt/speedtest-docker-stack/scripts/apply.sh
```

7. Rodar diagnóstico automático completo:

```bash
bash /opt/speedtest-docker-stack/scripts/diagnose.sh
```

Causas mais comuns de `502` neste projeto:
- `OoklaServer.properties` inválido ou incompleto.
- Processo Ookla não iniciou corretamente no container `_ookla`.
- Nome da instância divergente entre inventário e arquivos gerados.
- Alteração de inventário sem reaplicar `scripts/apply.sh`.
- DNS público apontando para destino incorreto (ex.: uma instância responde `200` de outro servidor enquanto as demais respondem via stack local).

### 10.4 Logs de operação

```bash
docker logs --tail=100 speedtest-docker-stack_speedtest01_ookla
docker logs --tail=100 speedtest-docker-stack_speedtest01_acme
```

---

## Passo 11 — Habilitar TLS (quando HTTP estiver 100% funcional)

1. Edite `/opt/speedtest-docker-stack/inventory.yml` e ajuste:
   - `tls_enabled: true`
   - `certbot_email` válido
2. Garanta DNS resolvendo corretamente para cada FQDN.
3. Reaplique:

```bash
bash /opt/speedtest-docker-stack/scripts/apply.sh
```

4. Execute scripts de ACME no diretório `/opt/speedtest-docker-stack/scripts/` conforme o fluxo do projeto.

**Boa prática aplicada:** primeiro validar camada HTTP/rede; só depois ativar emissão ACME para evitar rate limit desnecessário.

---

## Passo 12 — Escalar para novos medidores

Para incluir nova instância:

1. Adicione item em `/opt/speedtest-docker-stack/inventory.yml` com:
   - `name` único
   - `fqdn`
   - `ipv4` público dedicado
   - `ipv6` público dedicado
2. Adicione bloco correspondente em `/opt/speedtest-docker-stack/inventory.private.yml` (se necessário).
3. Reaplique:

```bash
bash /opt/speedtest-docker-stack/scripts/apply.sh
```

Resultado esperado: criação automática do par de containers (`<instancia>_ookla` + `<instancia>_acme`) e dos arquivos gerados da nova instância.

---

## Passo 13 — Operação diária e comandos úteis

```bash
# Render manual
python3 /opt/speedtest-docker-stack/scripts/render.py

# Ver containers da stack
docker compose --env-file /opt/speedtest-docker-stack/generated/.env \
  -f /opt/speedtest-docker-stack/generated/docker-compose.yml ps

# Reiniciar stack
docker compose --env-file /opt/speedtest-docker-stack/generated/.env \
  -f /opt/speedtest-docker-stack/generated/docker-compose.yml restart

# Inspecionar rede pública
docker network inspect speedtest-docker-stack_public_l3
```

---

## Passo 14 — Troubleshooting objetivo

- **Erro no render (`global sem chaves`)**: conferir campos obrigatórios no `inventory.yml`.
- **Container no ar sem tráfego externo**: validar roteamento de retorno no upstream (caso clássico em `ipvlan l3`).
- **Falha de TLS**: confirmar DNS público, porta 80 liberada e webroot compartilhado corretamente.
- **Instância com nome duplicado**: revisar `name` de `instances[]` para evitar sobreposição de configuração.

---

## Resumo executivo (o que fazer agora)

Se você está começando do zero, execute nesta ordem:

1. Instalar Docker e dependências Python.
2. Preencher `inventory.yml` e criar `inventory.private.yml`.
3. Rodar `python3 /opt/speedtest-docker-stack/scripts/render.py`.
4. Rodar `bash /opt/speedtest-docker-stack/scripts/apply.sh`.
5. Validar `docker compose ps`, `curl`, `docker logs`.
6. Só então habilitar TLS.

Esse fluxo reduz retrabalho, evita falhas de rede mascaradas e acelera o provisionamento em escala com padrão operacional consistente.
