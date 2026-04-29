# Loki Docker

Loki listo para producción en Docker Compose. Una instancia por sistema, con recursos mínimos para que convivan varios en el mismo host.

🇬🇧 [English version](README.md)

- **Loki:** v3.7.1 (pinneada)
- **Modos:** `monolithic` (default) | `scalable` (SSD: read/write/backend)
- **Storage:** `filesystem` (default, sin deps) | `s3` (MinIO externo)
- **Recursos:** reserva `0.25 CPU / 256M`, limit `1 CPU / 1G`
- **Retención default:** 90 días

Ver `PRD.md` para el diseño completo.

---

## Prerequisitos

El compose adjunta Loki a una network externa de Docker llamada `loki_router`. Esta network debe existir antes de levantar Loki, y cualquier servicio que Loki necesite alcanzar (MinIO, Grafana, etc.) debe estar también adjunto a ella.

```bash
docker network create --driver bridge loki_router
```

Si ya tenés MinIO corriendo en otra network, adjuntalo:

```bash
docker network connect loki_router minio
```

---

## Inicio rápido

```bash
# 1. Configurar
cp .env.example .env
# Editar .env: al menos LOKI_INSTANCE_NAME (y creds de S3 si usás backend s3)

# 2. Crear el directorio de datos
./scripts/init.sh

# 3. Ajustar ownership (Loki corre como uid 10001 dentro del contenedor)
sudo chown -R 10001:10001 ./data/loki

# 4. Levantar (el modo se lee de COMPOSE_PROFILES en .env)
docker compose up -d

# 5. Verificar
docker compose ps
curl -s http://localhost:3100/ready
```

El modo (`monolithic` | `scalable`) y el backend (`filesystem` | `s3`) se controlan **enteramente desde `.env`** — no hace falta pasar `--profile` ni nada en CLI.

---

## Múltiples Lokis en el mismo host

Cada sistema en su propia carpeta con su propio `.env`:

```
/opt/loki/
├── sistema-a/
│   ├── docker-compose.yml    (symlink o copia)
│   ├── .env                  (LOKI_INSTANCE_NAME=sistema-a, LOKI_HTTP_PORT=3100)
│   └── data/loki/
└── sistema-b/
    ├── docker-compose.yml
    ├── .env                  (LOKI_INSTANCE_NAME=sistema-b, LOKI_HTTP_PORT=3101)
    └── data/loki/
```

Cada `.env` debe tener:
- `LOKI_INSTANCE_NAME` único.
- `LOKI_HTTP_PORT` / `LOKI_GRPC_PORT` distintos si bindean al host.
- `S3_BUCKET` único por sistema (cuando usás backend `s3`).

---

## Storage backends

### `filesystem` (default)

- Chunks, índice y WAL en `LOKI_DATA_DIR` del host.
- Sin dependencias externas.
- Solo modo `monolithic`.

### `s3` (MinIO externo)

Pre-requisitos en MinIO:

1. Crear bucket dedicado (`loki-<instance-name>`).
2. Crear service account con policy de read/write sobre ese bucket.
3. Setear `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` en `.env`.

Si el endpoint usa TLS auto-firmado o lo accedés por IP, ajustar `S3_INSECURE` y `S3_FORCE_PATH_STYLE` según corresponda.

---

## Multi-tenant (`X-Scope-OrgID`)

- `LOKI_AUTH_ENABLED=false` (default): los clientes (Promtail/Alloy) **no** mandan `X-Scope-OrgID`. Todo va al tenant `fake`.
- `LOKI_AUTH_ENABLED=true`: cada request debe incluir `X-Scope-OrgID: <nombre>` (p.ej. `account1`). Loki separa logs por tenant.

Esto **no** es seguridad de red. Para proteger Loki de internet, usar reverse proxy (Traefik/nginx) con auth.

---

## Operación

```bash
# Logs
docker compose logs -f loki

# Stats
docker stats $(docker compose ps -q)

# Recargar config (corte breve de API, datos en RAM se preservan)
docker compose restart loki

# Apagar
docker compose down

# Apagar y borrar TODOS los datos (⚠️ destructivo)
docker compose down -v
sudo rm -rf ./data/loki
```

---

## Endpoints

| Endpoint | Para qué |
|----------|----------|
| `GET /ready` | Healthcheck (200 cuando está listo) |
| `GET /metrics` | Métricas Prometheus |
| `POST /loki/api/v1/push` | Ingesta de logs (Promtail/Alloy) |
| `GET /loki/api/v1/query_range` | Queries (Grafana) |

---

## Troubleshooting

**Loki no arranca, logs muestran "permission denied" en `/loki`:**
```bash
sudo chown -R 10001:10001 ./data/loki
```

**`/ready` devuelve 503 con "ingester not ready":**
Es normal los primeros ~30s. Si persiste, revisar `docker compose logs loki`.

**S3: "InvalidAccessKeyId" o "SignatureDoesNotMatch":**
- Verificar credenciales en `.env`.
- Confirmar `S3_FORCE_PATH_STYLE=true` para MinIO.
- Si endpoint es `http://`, setear `S3_INSECURE=true`.

**`network loki_router declared as external, but could not be found`:**
Crearla: `docker network create --driver bridge loki_router`.

**Picos de CPU sincronizados entre varios Lokis:**
El `compaction_interval=10m` corre a la vez en todos. Para desfasar, editar `config/loki-*.yaml` y darle un valor distinto a cada sistema (p.ej. `11m`, `13m`).
