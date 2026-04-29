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

# 2. Crear el directorio de datos y ajustar ownership (uid 10001 en el contenedor)
./scripts/init.sh

# 3. Levantar (el modo se lee de COMPOSE_PROFILES en .env)
docker compose up -d

# 4. Verificar
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

## Contrato de labels requeridos

Cada línea de log que entre a este Loki **debe** traer los siguientes labels. El dashboard provisto está armado alrededor de ellos; sin estos, los paneles aparecen vacíos.

| Label | Requerido | Ejemplo | Para qué |
|-------|-----------|---------|----------|
| `system` | sí | `payment`, `billing`, `auth` | Dominio de negocio. |
| `service` | sí | `account-service`, `transaction-service` | App específica dentro del system. |
| `instance` | sí | `1`, `2`, `account-service-prod-1` | Identificador de réplica/nodo. Mandar `1` incluso si hay una sola. |
| `level` | sí | `info`, `warn`, `error`, `debug` | Nivel de log. Requerido para los paneles de error/warning. |
| `env` | opcional | `production`, `staging` | Ambiente. Útil cuando un Loki recibe múltiples ambientes. |

> ⚠️ Loki **no** rechaza pushes por labels faltantes nativamente. El contrato se hace cumplir del lado del **cliente** (config de Alloy/Promtail) y se hace visible en el dashboard (logs sin `system`/`service`/`instance` simplemente no aparecen al filtrar).

> ⚠️ **No** usar valores de alta cardinalidad como labels (`request_id`, `trace_id`, `user_id`, `session_id`). Poner eso en la línea de log; cada valor único crea un stream nuevo y explota el índice de Loki.

### Ejemplo Alloy

```hcl
loki.source.file "app" {
  targets = [{
    __path__   = "/var/log/myapp/*.log",
    system     = "payment",
    service    = "account-service",
    instance   = "1",
    env        = "production",
  }]
  forward_to = [loki.write.local.receiver]
}

loki.write "local" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
    headers = {
      "X-Scope-OrgID" = "payment",  // por convención, tenant = system
    }
  }
}
```

### Ejemplo Promtail

```yaml
scrape_configs:
  - job_name: account-service
    static_configs:
      - targets: [localhost]
        labels:
          system:   payment
          service:  account-service
          instance: "1"
          env:      production
          __path__: /var/log/myapp/*.log

clients:
  - url: http://loki:3100/loki/api/v1/push
    tenant_id: payment
```

---

## Grafana (opcional)

El stack incluye un servicio opcional de Grafana con datasource Loki auto-provisionada y un dashboard inicial. Para habilitarlo, descomentá en `.env`:

```bash
COMPOSE_FILE=docker-compose.yml:docker-compose.grafana.yml
GRAFANA_ADMIN_PASSWORD=changeme    # default es admin/admin
```

Después `./scripts/init.sh && docker compose up -d`. Grafana queda en http://localhost:3000.

Qué se aprovisiona:
- **Datasource** `Loki Local` (uid `loki-${LOKI_INSTANCE_NAME}`) apuntando a esta instancia, con el header `X-Scope-OrgID: ${LOKI_INSTANCE_NAME}` ya configurado. Alloy/Promtail deben mandar el mismo valor.
- **Dashboard** `Loki — Overview` con:
  - Selector de **datasource** (para cambiar entre varios Lokis si aprovisionás más datasources).
  - Filtros de **Job** y **Level** (multi-valor, auto-descubiertos).
  - Caja de **Search** con regex libre sobre las líneas.
  - Stat panels de total / errores / warnings.
  - Time series de volumen de logs por nivel.
  - Top jobs por volumen (bar gauge).
  - Panel de logs con todo filtrado.

Convención de nombres por tenant: por default el tenant es igual a `LOKI_INSTANCE_NAME`. Los clientes Alloy/Promtail deben mandar ese mismo valor en el header `X-Scope-OrgID`. Si `LOKI_AUTH_ENABLED=false`, el header se manda pero Loki lo ignora — útil mientras estás cableando. Para usar un nombre de tenant distinto al instance name, setear `LOKI_TENANT` en `.env`.

---

## Referencia de configuración

Todas las variables se leen del `.env`. Todas son opcionales — si están comentadas o ausentes, se aplica el default mostrado abajo.

### General

| Variable | Default | Descripción |
|----------|---------|-------------|
| `LOKI_VERSION` | `3.7.1` | Tag de la imagen oficial `grafana/loki`. Pinneá una versión exacta. |
| `LOKI_INSTANCE_NAME` | `default` | Nombre único de la instancia. Se usa como sufijo del container_name y (por convención) como nombre del bucket en MinIO. |
| `COMPOSE_PROFILES` | `monolithic` | Modo de despliegue: `monolithic` (1 contenedor con todos los componentes) o `scalable` (read/write/backend, requiere backend s3). Variable nativa de Compose. |
| `LOKI_DATA_DIR` | `./data/loki` | Directorio del host donde Loki persiste WAL, índice TSDB, working dir del compactor y (solo en backend filesystem) chunks. |
| `LOKI_ANALYTICS_REPORTING` | `false` | Si es `true`, envía diagnósticos de uso a Grafana Labs. Apagado por default. |

### Recursos

| Variable | Default | Descripción |
|----------|---------|-------------|
| `LOKI_CPU_RESERVATION` | `0.25` | CPU mínimo garantizado por Docker para el contenedor. |
| `LOKI_MEMORY_RESERVATION` | `256M` | Memoria mínima garantizada por Docker para el contenedor. |
| `LOKI_CPU_LIMIT` | `1.0` | Tope máximo de CPU. |
| `LOKI_MEMORY_LIMIT` | `1G` | Tope máximo de memoria. Si lo supera, Docker mata el contenedor por OOM. |

### Red

| Variable | Default | Descripción |
|----------|---------|-------------|
| `LOKI_HTTP_PORT` | `3100` | Puerto del host para la API HTTP de Loki. Cambialo si choca con otro Loki en el mismo host. |
| `LOKI_GRPC_PORT` | `9095` | Puerto del host para la API gRPC de Loki. |
| `LOKI_ROUTER_NETWORK` | `loki_router` | Network externa de Docker compartida con MinIO/Grafana/etc. Debe existir antes del `up`. |

### Retención y límites de ingesta

| Variable | Default | Descripción |
|----------|---------|-------------|
| `LOKI_RETENTION_PERIOD` | `2160h` (90d) | Cuánto tiempo se guardan los logs antes de que el compactor los borre. |
| `LOKI_MAX_QUERY_LENGTH` | `2161h` | Rango máximo de tiempo que puede cubrir una query. Un poco más que retention para cubrir todo el rango. |
| `LOKI_INGESTION_RATE_MB` | `4` | Tasa sostenida de ingesta por tenant, en MB/s. |
| `LOKI_INGESTION_BURST_MB` | `6` | Burst permitido por encima de la tasa sostenida, en MB. |

### Multi-tenant

| Variable | Default | Descripción |
|----------|---------|-------------|
| `LOKI_AUTH_ENABLED` | `false` | Si es `true`, cada push/query debe incluir `X-Scope-OrgID: <nombre>` y Loki separa los datos por tenant. Si es `false`, todo va al tenant `fake`. No es autenticación de red. |

### Storage backend

| Variable | Default | Descripción |
|----------|---------|-------------|
| `LOKI_STORAGE_BACKEND` | `filesystem` | Dónde viven los chunks: `filesystem` (disco local, solo single-node) o `s3` (MinIO/S3 externo, requerido para modo scalable). |

### Grafana (solo cuando se activa vía `COMPOSE_FILE`)

| Variable | Default | Descripción |
|----------|---------|-------------|
| `COMPOSE_FILE` | _(no definido)_ | Setear a `docker-compose.yml:docker-compose.grafana.yml` para levantar Grafana junto con Loki. |
| `GRAFANA_VERSION` | `13.0.1` | Tag de la imagen oficial `grafana/grafana`. |
| `GRAFANA_ADMIN_USER` | `admin` | Usuario admin inicial. |
| `GRAFANA_ADMIN_PASSWORD` | `admin` | Password admin inicial. **Cambiar en producción**. |
| `GRAFANA_LOG_LEVEL` | `warn` | Verbosidad del log de Grafana. |
| `GRAFANA_PORT` | `127.0.0.1:3000` | Puerto del host para la UI de Grafana. Bindea a loopback por default; cambiar a `0.0.0.0:3000` para exponer en LAN. |
| `GRAFANA_LOKI_URL` | `http://loki:3100` | URL que usa Grafana para llegar a Loki (red compartida). |
| `GRAFANA_DATA_DIR` | `./data/grafana` | Directorio del host para el SQLite de Grafana, plugins, etc. |
| `GRAFANA_CPU_RESERVATION` | `0.1` | CPU mínimo reservado. |
| `GRAFANA_MEMORY_RESERVATION` | `128M` | Memoria mínima reservada. |
| `GRAFANA_CPU_LIMIT` | `1.0` | Tope de CPU. |
| `GRAFANA_MEMORY_LIMIT` | `512M` | Tope de memoria. |

### S3 / MinIO (solo cuando `LOKI_STORAGE_BACKEND=s3`)

| Variable | Default | Descripción |
|----------|---------|-------------|
| `S3_ENDPOINT` | _(vacío)_ | URL del MinIO/S3. Usá `https://` si va detrás de reverse proxy con TLS. |
| `S3_BUCKET` | _(vacío)_ | Bucket dedicado a esta instancia. Debe existir antes de levantar Loki. |
| `S3_ACCESS_KEY` | _(vacío)_ | Access key del service account con permisos read/write sobre el bucket. |
| `S3_SECRET_KEY` | _(vacío)_ | Secret key del service account. |
| `S3_REGION` | `us-east-1` | Requerido por el SDK de AWS; MinIO la ignora. |
| `S3_FORCE_PATH_STYLE` | `true` | Usar URLs path-style (`endpoint/bucket/...`). MinIO lo requiere. |
| `S3_INSECURE` | `false` | Poner `true` solo cuando `S3_ENDPOINT` es `http://` (sin TLS). |

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

## 👨‍💻 Autor

<div align="center">
  <img src="https://github.com/villcabo.png" width="100" height="100" style="border-radius: 50%;" alt="villcabo">
  <br/>
  <strong>Bismarck Villca</strong>
  <br/>
  <br/>
  <a href="https://github.com/villcabo">
    <img src="https://img.shields.io/badge/GitHub-villcabo-blue?style=for-the-badge&logo=github" alt="GitHub Profile">
  </a>
  <br/>
  <a href="https://linkedin.com/in/villcabo">
    <img src="https://img.shields.io/badge/LinkedIn-villcabo-0A66C2?style=for-the-badge&logo=linkedin" alt="LinkedIn Profile">
  </a>
  <br/>
  <a href="https://facebook.com/villcabo">
    <img src="https://img.shields.io/badge/Facebook-villcabo-1877F2?style=for-the-badge&logo=facebook" alt="Facebook Profile">
  </a>
  <br/>
  <a href="https://x.com/villcabo">
    <img src="https://img.shields.io/badge/X-@villcabo-000000?style=for-the-badge&logo=x" alt="X Profile">
  </a>
  <br/>
</div>

---

⭐ **Si este proyecto te ayudó, ¡considerá darle una estrellita!** ⭐
