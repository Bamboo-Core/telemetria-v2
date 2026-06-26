# Design — Pacote de Telemetria com InfluxDB v2 (CPUs sem AVX2)

**Data:** 2026-06-26
**Contexto:** o pacote principal usa InfluxDB 3 Core, cujo binário (motor IOx, em
Rust) exige instruções **AVX2/BMI2** (CPU Intel Haswell 2013+ / AMD Zen). Em hosts
antigos (ex.: Xeon E5-4640 Sandy Bridge, 2012) o InfluxDB 3 quebra com `SIGILL`
(exit 132) antes de logar qualquer coisa. Comprovado por teste diferencial:
a VM base (Xeon E5-2696 v4, tem AVX2) roda; a VM `kuantics` (E5-4640, sem AVX2)
falha. Este pacote é a variante para esses hosts antigos.

## Objetivo

Mesmo resultado funcional do pacote v3 (Telegraf Huawei + gNMI → InfluxDB → Kuantics),
porém usando **InfluxDB v2** (em Go), que roda em CPUs sem AVX2.

## Decisões

- **InfluxDB v2** (`influxdb:2.7`) na porta 8086.
- **UI nativa do v2** (na 8086) — dispensa o container `influxdb3-ui` (que é v3-only).
- **org=kuantics, bucket=telemetria** (v2 usa org + bucket no lugar de "database").
- **Auto-setup** do v2 via `DOCKER_INFLUXDB_INIT_*` (org, bucket, usuário e token
  criados no 1º boot) — mais simples que o bootstrap por CLI do v3.
- **Mesma imagem Huawei** (`ghcr.io/bamboo-core/telemetria`) — o `outputs.influxdb_v2`
  do Telegraf escreve tanto em v2 quanto em v3.
- **Repositório separado:** `Bamboo-Core/telemetria-v2`.

## Arquitetura

| Serviço | Imagem | Porta | Papel |
|---|---|---|---|
| influxdb2 | `influxdb:2.7` | 8086 | Banco + UI web nativa |
| telegraf-huawei | `ghcr.io/bamboo-core/telemetria` | 57400 (host) | Coleta passiva Huawei MDT |
| telegraf-gnmi | `telegraf:1.32` | — | Coleta ativa gNMI + métricas locais |
| gnmic-nokia (perfil `nokia`) | `ghcr.io/openconfig/gnmic` | host | Nokia dial-out (opcional) |

## Diferenças em relação ao v3

| Aspecto | v3 | v2 |
|---|---|---|
| Banco / porta | influxdb:3-core / 8181 | influxdb:2.7 / 8086 |
| UI | container influxdb3-ui separado | nativa no v2 |
| Modelo de dados | database `telemetria` | org `kuantics` + bucket `telemetria` |
| Bootstrap | `influxdb3 create token` pós-start | auto-setup `DOCKER_INFLUXDB_INIT_*` |
| Telegraf output | `influxdb_v2` sem org | `influxdb_v2` com `organization` |

## Fluxo do instalar.sh
1. Verifica Docker/Compose.
2. Cria `.env`; gera token (`openssl rand -hex 32`) e senha admin (1ª vez).
3. Sobe `influxdb2` → auto-setup cria org/bucket/usuário/token; espera `/health`.
4. Sobe o Telegraf.
5. Imprime credenciais da UI (usuário/senha) e dados do Kuantics (URL/org/bucket/token).

Idempotente: reaproveita token/senha já existentes no `.env`. Reset total:
`docker compose down && rm -rf data .env`.

## Configs Telegraf
Idênticas ao v3 (exemplos, processors, fix_fields), mudando apenas o bloco
`[[outputs.influxdb_v2]]` para incluir `organization` e apontar para a 8086.

## Conexão Kuantics
`http://IP_DA_VM:8086`, org `kuantics`, bucket `telemetria`, token do `.env`.

## Fora de escopo
- Migração de dados entre v2 e v3.
- Rebuild automático da imagem Huawei (em `build/publicar.sh`, manual).
