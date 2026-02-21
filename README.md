# speedtest-docker-stack

Guia operacional **detalhado** para provisionar medidores Ookla em Debian 12 com Docker, usando uma arquitetura escalável por instância:

- 1 IPv4 público dedicado por medidor (uso de /32 por instância)
- 1 IPv6 público dedicado por medidor (uso de /128 por instância)
- Host com rede privada de gerenciamento separada
- Publicação de serviços por containers com rede `ipvlan` L3

Repositório oficial: `https://github.com/vinicius-st1/speedtest-docker-stack.git`  
Diretório operacional padrão: `/opt/speedtest-docker-stack`

> ⚠️ **Regra operacional obrigatória:** antes de executar qualquer passo deste guia na VM, sempre atualize o repositório local com `git fetch` + `git pull --ff-only origin main`.

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
- `/opt/speedtest-docker-stack/scripts/diagnose-stack.sh`
  Diagnóstico de erro 500/502 (logs, DNS interno e conectividade acme -> ookla).
- `/opt/speedtest-docker-stack/scripts/bootstrap-host.sh`
  Bootstrap do host Debian 12 (pacotes, Docker oficial, sysctl e módulos de kernel).
- `/opt/speedtest-docker-stack/templates/docker-compose.yml.j2`  
  Modelo dos serviços e rede pública `ipvlan` L3.

---

## Passo 1 — Preparar o host Debian 12

> Objetivo: garantir base estável e reproduzível para operação de containers.

### 1.1 Bootstrap automatizado (recomendado)

Arquivo: `/opt/speedtest-docker-stack/scripts/bootstrap-host.sh`

```bash
cd /opt/speedtest-docker-stack
sudo bash /opt/speedtest-docker-stack/scripts/bootstrap-host.sh
```

Esse script aplica em modo idempotente:

- Pacotes base para operação e troubleshooting.
- Repositório oficial do Docker + Docker Engine e plugins.
- Tuning de kernel em `/etc/sysctl.d/99-speedtest-tuning.conf`.
- Módulos TCP adicionais em `/etc/modules-load.d/speedtest.conf`.

### 1.2 Passo manual (caso prefira executar linha a linha)

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
- **Gateway IPv4 (gerência):** `10.4.18.193`
- **IPv6 (gerência):** `2804:60d4:300:80::3a/126`
- **Gateway IPv6 (gerência):** `2804:60d4:300:80::39`
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
    ookla:
      properties_raw: ""

  - name: "speedtest02"
    fqdn: "speedtest02.st1internet.com.br"
    ipv4: "45.179.238.60"
    ipv6: "2804:60D4:45:179:238::60"
    ookla:
      properties_raw: ""
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

Causas mais comuns de `502` neste projeto:
- `OoklaServer.properties` inválido ou incompleto.
- Processo Ookla não iniciou corretamente no container `_ookla`.
- Nome da instância divergente entre inventário e arquivos gerados.
- Alteração de inventário sem reaplicar `scripts/apply.sh`.

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


## Passo 15 — Runbook detalhado (copiar e executar)

> Este bloco é um **passo a passo completo e sequencial**, do zero até validação final.
> **Sempre comece pelo Passo 15.0 (atualizar do GitHub)** antes de qualquer outro comando.

### 15.0 Atualizar arquivos do projeto (obrigatório antes de iniciar)

Arquivo de referência: `/opt/speedtest-docker-stack/.git`

```bash
cd /opt/speedtest-docker-stack
git fetch origin
git checkout main
git pull --ff-only origin main
git log -1 --oneline
```

Valide que os arquivos esperados existem localmente:

```bash
test -f /opt/speedtest-docker-stack/scripts/bootstrap-host.sh && echo "OK bootstrap-host.sh"
test -f /opt/speedtest-docker-stack/scripts/apply.sh && echo "OK apply.sh"
test -f /opt/speedtest-docker-stack/scripts/preflight.sh && echo "OK preflight.sh"
test -f /opt/speedtest-docker-stack/scripts/diagnose-stack.sh && echo "OK diagnose-stack.sh"
```

Se `diagnose-stack.sh` não existir, significa que sua VM ainda não baixou a revisão mais recente da `main` no GitHub.

> **Importante:** alterações feitas por PR só chegam na sua VM depois de **merge no GitHub** na `main`.
> Se você fizer `git pull origin main` antes do merge, sua VM continuará sem as mudanças novas.
> Após criar o PR, finalize no GitHub: **Review/Approve -> Merge pull request -> Confirm merge**.

Diagnóstico rápido para confirmar origem/estado do repositório local:

```bash
cd /opt/speedtest-docker-stack
git remote -v
git branch -vv
git log --oneline -n 5 --decorate
git log --oneline origin/main -n 5
```

### 15.1 Clonar projeto no diretório padrão

```bash
sudo mkdir -p /opt
cd /opt
sudo git clone https://github.com/vinicius-st1/speedtest-docker-stack.git
sudo chown -R "$USER":"$USER" /opt/speedtest-docker-stack
cd /opt/speedtest-docker-stack
```

### 15.2 Preparar host Debian 12 (automático)

Arquivo executado: `/opt/speedtest-docker-stack/scripts/bootstrap-host.sh`

> Se o arquivo não existir na sua VM, você provavelmente está em um clone antigo do `main`.
> Atualize o repositório antes de continuar:

```bash
cd /opt/speedtest-docker-stack
git fetch origin
git pull --ff-only origin main
```

Valide que o script existe:

```bash
test -f /opt/speedtest-docker-stack/scripts/bootstrap-host.sh && echo "bootstrap encontrado"
```

Se ainda não existir, execute o **Passo 1.2 (manual)** deste README para preparar o host sem o script.

```bash
cd /opt/speedtest-docker-stack
sudo bash /opt/speedtest-docker-stack/scripts/bootstrap-host.sh
```

Validação imediata:

```bash
docker --version
docker compose version
sysctl net.ipv4.tcp_congestion_control
```

### 15.3 Configurar inventário com as 4 instâncias

Arquivo: `/opt/speedtest-docker-stack/inventory.yml`

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
    ookla:
      properties_raw: ""

  - name: "speedtest02"
    fqdn: "speedtest02.st1internet.com.br"
    ipv4: "45.179.238.60"
    ipv6: "2804:60D4:45:179:238::60"
    ookla:
      properties_raw: ""

  - name: "speedtest03"
    fqdn: "speedtest03.st1internet.com.br"
    ipv4: "45.179.238.61"
    ipv6: "2804:60D4:45:179:238::61"
    ookla:
      properties_raw: ""

  - name: "speedtest04"
    fqdn: "speedtest04.st1internet.com.br"
    ipv4: "45.179.238.62"
    ipv6: "2804:60D4:45:179:238::62"
    ookla:
      properties_raw: ""
```

### 15.4 Criar inventário privado

Arquivo final: `/opt/speedtest-docker-stack/inventory.private.yml`

```bash
cp /opt/speedtest-docker-stack/inventory.private.yml.example /opt/speedtest-docker-stack/inventory.private.yml
```

> **Atenção:** edite **`inventory.private.yml`** (arquivo final), e não o `inventory.private.yml.example`.
> O arquivo `.example` é somente modelo.

```bash
nano /opt/speedtest-docker-stack/inventory.private.yml
```

> **Importante:** preencha `properties_raw` com o bloco oficial de cada servidor Ookla.
> Com `properties_raw` vazio o backend não sobe corretamente e o Nginx retorna **502 Bad Gateway**.

Exemplo de estrutura (substitua pelo conteúdo oficial de cada instância):

```yaml
instances:
  - name: "speedtest01"
    ookla:
      properties_raw: |
        # bloco oficial fornecido pela Ookla para speedtest01
        # key=value

  - name: "speedtest02"
    ookla:
      properties_raw: |
        # bloco oficial fornecido pela Ookla para speedtest02
        # key=value

  - name: "speedtest03"
    ookla:
      properties_raw: |
        # bloco oficial fornecido pela Ookla para speedtest03
        # key=value

  - name: "speedtest04"
    ookla:
      properties_raw: |
        # bloco oficial fornecido pela Ookla para speedtest04
        # key=value
```

Valide se você realmente substituiu os placeholders (antes do preflight):

```bash
cd /opt/speedtest-docker-stack
# usa grep (padrão do Debian). Se quiser, você pode usar rg/ripgrep.
grep -nE "# key=value|bloco oficial fornecido" /opt/speedtest-docker-stack/inventory.private.yml && echo "ERRO: ainda há placeholders"
```

Se aparecer `ERRO: ainda há placeholders`, edite `/opt/speedtest-docker-stack/inventory.private.yml` e troque o conteúdo de exemplo pelo bloco oficial de cada servidor.

O que deve ser preenchido em cada `properties_raw`:
- cole o bloco **completo** entregue pela Ookla para aquela instância (`speedtest01`, `speedtest02`, etc);
- não deixe comentários de exemplo como `# key=value`;
- não reutilize o mesmo bloco entre instâncias diferentes;
- mantenha o texto exatamente como recebido (uma chave por linha, sem aspas extras);
- **remova** linhas `openSSL.server.certificateFile` e `openSSL.server.privateKeyFile` do `properties_raw` neste projeto (TLS é no Nginx/acme).

Parâmetros necessários (base mínima) que você enviou e devem existir por instância:

> **Importante:** esta base não substitui o bloco oficial completo da Ookla (identificadores/chaves de registro do servidor).
> Se faltar qualquer parâmetro obrigatório da sua conta Ookla, o backend pode responder `500 Internal Server Error`.

```properties
OoklaServer.tcpPorts = 5060,8080
OoklaServer.udpPorts = 5060,8080
OoklaServer.useIPv6 = true
OoklaServer.allowedDomains = *.ookla.com, *.speedtest.net, *.st1internet.com.br
OoklaServer.userAgentFilterEnabled = true
OoklaServer.workerThreadPool.capacity = 30000
OoklaServer.ipTracking.maxIdleAgeMinutes = 35
OoklaServer.ipTracking.maxConnPerIp = 5
OoklaServer.ipTracking.maxConnPerBucketPerIp = 10
OoklaServer.clientAuthToken.denyInvalid = true
OoklaServer.websocket.frameSizeLimitBytes = 5242880
```

> Não usar no `properties_raw` deste projeto: `openSSL.server.certificateFile` e `openSSL.server.privateKeyFile`.

Exemplo de preenchimento (estrutura):

```yaml
instances:
  - name: "speedtest01"
    ookla:
      properties_raw: |
        # COLE AQUI O BLOCO OFICIAL DA OOKLA DO SPEEDTEST01
        # Exemplo ilustrativo:
        # OoklaServer.serverId = SEU_SERVER_ID_01
        # OoklaServer.apiKey = SUA_API_KEY_01

  - name: "speedtest02"
    ookla:
      properties_raw: |
        # COLE AQUI O BLOCO OFICIAL DA OOKLA DO SPEEDTEST02

  - name: "speedtest03"
    ookla:
      properties_raw: |
        # COLE AQUI O BLOCO OFICIAL DA OOKLA DO SPEEDTEST03

  - name: "speedtest04"
    ookla:
      properties_raw: |
        # COLE AQUI O BLOCO OFICIAL DA OOKLA DO SPEEDTEST04
```

Se após aplicar a stack você receber `500 Internal Server Error`, rode o diagnóstico automatizado:

```bash
bash /opt/speedtest-docker-stack/scripts/diagnose-stack.sh
```

Esse script coleta logs de `*_acme` e `*_ookla`, testa resolução interna e acesso `acme -> ookla:8080` para cada instância.

### 15.5 Validar e gerar artefatos

```bash
cd /opt/speedtest-docker-stack
bash /opt/speedtest-docker-stack/scripts/preflight.sh
```

### 15.6 Aplicar stack

```bash
bash /opt/speedtest-docker-stack/scripts/apply.sh
```

### 15.7 Validar containers e conectividade

```bash
docker compose --env-file /opt/speedtest-docker-stack/generated/.env \
  -f /opt/speedtest-docker-stack/generated/docker-compose.yml ps

curl -I http://speedtest01.st1internet.com.br
curl -I http://speedtest02.st1internet.com.br
curl -I http://speedtest03.st1internet.com.br
curl -I http://speedtest04.st1internet.com.br
```

### 15.8 Habilitar TLS após HTTP ok

1. Ajustar `tls_enabled: true` no arquivo `/opt/speedtest-docker-stack/inventory.yml`.
2. Reaplicar stack:

```bash
bash /opt/speedtest-docker-stack/scripts/apply.sh
```

3. Executar fluxo ACME do projeto para emissão/renovação.

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
