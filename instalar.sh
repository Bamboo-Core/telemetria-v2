#!/usr/bin/env bash
###############################################################################
# instalar.sh — Bootstrap da stack de Telemetria (InfluxDB v2 + Telegraf)
#
# Variante para CPUs SEM AVX2 (Sandy/Ivy Bridge). Em hardware moderno use o v3.
#
# O que faz (idempotente — pode rodar de novo sem quebrar):
#   1. Verifica Docker e Docker Compose
#   2. Cria .env e gera o token + a senha admin (só na 1ª vez)
#   3. Sobe o InfluxDB v2, que se auto-configura (org, bucket, usuário, token)
#   4. Sobe o Telegraf (Huawei e gNMI)
#   5. Imprime os dados de acesso (UI) e o que cadastrar no Kuantics
#
# Uso:  ./instalar.sh
###############################################################################
set -euo pipefail

cd "$(dirname "$0")"

B="\033[1m"; G="\033[32m"; Y="\033[33m"; R="\033[31m"; N="\033[0m"
info() { printf "${B}==>${N} %s\n" "$1"; }
ok()   { printf "${G}  ✓${N} %s\n" "$1"; }
warn() { printf "${Y}  !${N} %s\n" "$1"; }
die()  { printf "${R}ERRO:${N} %s\n" "$1" >&2; exit 1; }

# --- 1. Pré-requisitos -------------------------------------------------------
info "Verificando pré-requisitos"
command -v docker >/dev/null 2>&1 || die "Docker não encontrado. Instale o Docker antes de continuar."
docker compose version >/dev/null 2>&1 || die "'docker compose' (plugin v2) não encontrado. Atualize o Docker."
docker info >/dev/null 2>&1 || die "O daemon do Docker não está respondendo (permissão? tente sudo ou adicione seu usuário ao grupo docker)."
ok "Docker e Docker Compose OK"

# --- 2. .env, token e senha admin -------------------------------------------
info "Preparando o .env"
if [ ! -f .env ]; then
  cp .env.example .env
  ok "Criado .env a partir do .env.example"
fi

# Token admin (gera na 1ª vez)
CURRENT_TOKEN="$(grep '^INFLUX_TOKEN=' .env | cut -d= -f2- || true)"
if [ -z "$CURRENT_TOKEN" ] || [ "$CURRENT_TOKEN" = "trocar-me" ]; then
  TOKEN="$(openssl rand -hex 32)"
  sed -i.bak "s|^INFLUX_TOKEN=.*|INFLUX_TOKEN=${TOKEN}|" .env && rm -f .env.bak
  ok "Token admin gerado"
else
  warn "Token admin já existente no .env (mantido)"
fi

# Senha admin (gera na 1ª vez)
CURRENT_PASS="$(grep '^INFLUXDB_ADMIN_PASSWORD=' .env | cut -d= -f2- || true)"
if [ -z "$CURRENT_PASS" ] || [ "$CURRENT_PASS" = "trocar-me" ]; then
  PASS="$(openssl rand -hex 16)"
  sed -i.bak "s|^INFLUXDB_ADMIN_PASSWORD=.*|INFLUXDB_ADMIN_PASSWORD=${PASS}|" .env && rm -f .env.bak
  ok "Senha admin gerada"
else
  warn "Senha admin já existente no .env (mantida)"
fi

# Carrega valores finais do .env para o resumo
TOKEN="$(grep '^INFLUX_TOKEN=' .env | cut -d= -f2-)"
ORG="$(grep '^INFLUX_ORG=' .env | cut -d= -f2-)"
BUCKET="$(grep '^INFLUX_BUCKET=' .env | cut -d= -f2-)"
ADMIN_USER="$(grep '^INFLUXDB_ADMIN_USER=' .env | cut -d= -f2-)"
ADMIN_PASS="$(grep '^INFLUXDB_ADMIN_PASSWORD=' .env | cut -d= -f2-)"

# --- 3. Diretório e InfluxDB v2 (auto-setup) --------------------------------
info "Criando diretório de dados"
mkdir -p data
ok "Diretório pronto"

info "Subindo o InfluxDB v2 (faz o setup automático no 1º boot)"
docker compose up -d influxdb2

info "Aguardando o InfluxDB ficar pronto (porta 8086)"
for i in $(seq 1 60); do
  if curl -fsS "http://localhost:8086/health" >/dev/null 2>&1; then
    ok "InfluxDB respondendo"; break
  fi
  [ "$i" = "60" ] && die "InfluxDB não respondeu em 60s. Veja: docker logs influxdb2"
  sleep 1
done

# --- 4. Sobe o restante da stack --------------------------------------------
info "Subindo o Telegraf"
docker compose up -d
ok "Stack no ar"

# --- 5. Resumo ---------------------------------------------------------------
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; IP="${IP:-<IP_DA_VM>}"
echo
printf "${G}${B}========================================================${N}\n"
printf "${G}${B} Telemetria (InfluxDB v2) instalada com sucesso${N}\n"
printf "${G}${B}========================================================${N}\n"
echo
echo "  Interface web (UI):  http://${IP}:8086"
printf "    usuário:  ${B}%s${N}\n" "${ADMIN_USER}"
printf "    senha:    ${B}%s${N}\n" "${ADMIN_PASS}"
echo
echo "  Coleta Huawei (passiva): aponte o telemetry dos equipamentos para"
echo "                           ${IP}:57400 (dial-out gRPC)."
echo
echo "  Coleta gNMI (manual): cadastre equipamentos copiando modelos de"
echo "                        exemplos/ para telegraf.d/ e rode:"
echo "                        docker compose restart telegraf-gnmi"
echo
printf "${Y}${B}  ┌──────────────────────────────────────────────────────────┐${N}\n"
printf "${Y}${B}  │  CADASTRE ESTES DADOS NO KUANTICS                         │${N}\n"
printf "${Y}${B}  └──────────────────────────────────────────────────────────┘${N}\n"
echo "     Host / URL:  http://${IP}:8086"
echo "     Organização: ${ORG}"
echo "     Bucket:      ${BUCKET}"
printf "     Token:       ${B}%s${N}\n" "${TOKEN}"
echo
echo "     (esses valores também ficam salvos no .env)"
echo
echo "  Status:  docker compose ps"
echo "  Logs:    docker logs -f telegraf-gnmi   |   docker logs -f influxdb2"
echo
