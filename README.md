# Stack de Telemetria (InfluxDB v2) — Telegraf (Huawei + gNMI)

Variante do pacote de telemetria que usa **InfluxDB v2** em vez do v3.

> **Quando usar este pacote:** quando a CPU do host **não tiver AVX2** (ex.: Intel
> Sandy/Ivy Bridge — Xeon E5 v1/v2). O InfluxDB **v3** exige AVX2 e quebra com
> `SIGILL` nessas CPUs; o **v2** (em Go) roda em processadores antigos.
> Em hardware moderno (com AVX2), prefira o pacote v3.
>
> Verifique a CPU do host: `grep -qo avx2 /proc/cpuinfo && echo "tem AVX2 (use v3)" || echo "sem AVX2 (use este, v2)"`

```
[Equipamentos] → [Telegraf na VM] → [InfluxDB v2 (+ UI nativa)] → [Kuantics]
```

Há **duas frentes de coleta**, independentes:

| Frente | Como funciona | Equipamentos | Onde configurar |
|---|---|---|---|
| **Huawei (passiva)** | O equipamento **empurra** os dados para a VM (dial-out gRPC) | Huawei VRP | Nada por-equipamento na VM; aponte o `telemetry` do Huawei para `IP_DA_VM:57400` |
| **gNMI (ativa/manual)** | A VM **conecta** em cada equipamento (dial-in) | Juniper, Arista, Cisco, Nokia | Cadastre cada equipamento copiando um modelo de `exemplos/` para `telegraf.d/` |

---

## Pré-requisitos

- Linux x86-64 com **Docker** e **Docker Compose v2**
- Portas livres na VM: `8086` (InfluxDB + UI), `57400` (Huawei dial-out)
- Acesso de saída para `ghcr.io` e Docker Hub (baixar as imagens)

Verifique:
```bash
docker --version
docker compose version
```

---

## Instalação (1 comando)

```bash
git clone https://github.com/Bamboo-Core/telemetria-v2.git telemetria
cd telemetria
./instalar.sh
```

O `instalar.sh` é idempotente e faz tudo: cria o `.env`, gera o token e a senha
admin, sobe o InfluxDB v2 (que se **auto-configura**: org, bucket, usuário e token)
e sobe o Telegraf. Ao final imprime as credenciais da UI e os dados do Kuantics.

> A imagem do Telegraf-Huawei (`ghcr.io/bamboo-core/telemetria:latest`) é a **mesma**
> do pacote v3 — o plugin escreve via API InfluxDB v2, que serve para v2 e v3.

---

## Como o Telegraf se conecta ao InfluxDB (automático)

**Nada manual.** O `instalar.sh` gera o token e o compose injeta
`INFLUX_URL`/`INFLUX_TOKEN`/`INFLUX_ORG`/`INFLUX_BUCKET` nos dois coletores:

- `telegraf-huawei` → `http://127.0.0.1:8086` (rede do host)
- `telegraf-gnmi`   → `http://influxdb2:8086` (rede interna)

Cada `telegraf-*.conf` tem um bloco `[[outputs.influxdb_v2]]` que usa essas
variáveis. Subiu a stack, o Telegraf já está escrevendo no bucket.

**Conferir que os dados chegam** (deve retornar linhas de `cpu`, `mem`, etc.):
```bash
docker exec influxdb2 influx query \
  --org "$(grep ^INFLUX_ORG= .env | cut -d= -f2)" \
  --token "$(grep ^INFLUX_TOKEN= .env | cut -d= -f2)" \
  'from(bucket:"telemetria") |> range(start:-5m) |> limit(n:5)'
```
Ou abra a UI em `http://IP_DA_VM:8086` → **Data Explorer**.

---

## Cadastrar equipamentos gNMI (Juniper / Arista / Cisco)

1. Preencha as credenciais no `.env` (`JUNIPER_USER`, `ARISTA_USER`, ...).
2. Copie o modelo do fabricante para `telegraf.d/`, um arquivo por equipamento:
   ```bash
   cp exemplos/arista.conf.exemplo telegraf.d/arista-sw01.conf
   # edite o IP em telegraf.d/arista-sw01.conf
   ```
3. Recarregue o coletor:
   ```bash
   docker compose restart telegraf-gnmi
   ```

Equipamentos do mesmo fabricante com a mesma credencial podem ser listados juntos
em `addresses = ["ip1:porta", "ip2:porta"]` dentro de um único arquivo.

### Nokia (opcional, via gnmic)
```bash
cp exemplos/nokia-gnmic.yaml.exemplo gnmic.yaml   # edite targets/credenciais/token
# ajuste o output do gnmic.yaml para o bucket/org/token do v2 (porta 8086)
docker compose --profile nokia up -d
```

---

## Conectar no Kuantics

No cadastro da fonte de telemetria do Kuantics, use:

| Campo | Valor |
|---|---|
| Host / URL | `http://IP_DA_VM:8086` |
| Organização | `kuantics` |
| Bucket | `telemetria` |
| Token | conteúdo de `INFLUX_TOKEN` no `.env` (impresso ao final do `instalar.sh`) |

---

## Operação

```bash
docker compose ps                      # status dos serviços
docker logs -f telegraf-gnmi           # logs do coletor gNMI
docker logs -f telegraf-huawei         # logs do coletor Huawei
docker logs -f influxdb2               # logs do banco
```

Para **resetar do zero** (apaga todos os dados e a configuração):
```bash
docker compose down
rm -rf data .env
./instalar.sh
```

---

## Solução de problemas

| Sintoma | Causa provável / ação |
|---|---|
| InfluxDB reinicia com `exit 132` / `SIGILL` | A CPU não tem AVX2 **e** você está usando a imagem v3 por engano. Este pacote usa v2 (`influxdb:2.7`), que não tem esse problema — confirme a imagem no `docker-compose.yml`. |
| `unauthorized` / `401` nos logs do Telegraf | Token/org/bucket divergentes. Confira o `.env` e rode `docker compose up -d --force-recreate`. |
| `denied` ao baixar telegraf-huawei | Imagem GHCR não pública ou falta `docker login ghcr.io`. |
| `bind: address already in use` | Porta 8086/57400 ocupada. Veja `sudo ss -tlnp`. |
| Equipamento gNMI não conecta (`i/o timeout`) | Conectividade/credencial. Teste `telnet IP porta` da VM e revise usuário/senha. |
| Sem dados na UI | Confira `docker logs telegraf-*` por erros de write e se o bucket `telemetria` existe (UI → Buckets). |

---

## Estrutura

```
telemetria-v2/
├── docker-compose.yml        # influxdb2 + telegraf-huawei + telegraf-gnmi (+ gnmic opcional)
├── instalar.sh               # bootstrap 1-comando
├── .env.example              # modelo de variáveis (vira .env)
├── telegraf-huawei.conf      # config da coleta Huawei (passiva)
├── telegraf-gnmi.conf        # base da coleta gNMI + processors (sem credenciais)
├── telegraf.d/               # arquivos de equipamentos (mesclados ao gnmi)
│   └── fix_fields.conf
├── exemplos/                 # modelos por fabricante (copiar p/ telegraf.d/)
│   ├── juniper.conf.exemplo
│   ├── arista.conf.exemplo
│   ├── cisco.conf.exemplo
│   └── nokia-gnmic.yaml.exemplo
└── build/                    # OPCIONAL — rebuild da imagem Huawei (mesma do v3)
    ├── Dockerfile
    ├── generate_paths.go
    ├── telegraf.conf
    └── publicar.sh
```
