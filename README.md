# Loki Docker

Production-ready Loki on Docker Compose. One instance per system, minimal resources so multiple instances can coexist on the same host.

🇪🇸 [Versión en español](README.es.md)

- **Loki:** v3.7.1 (pinned)
- **Modes:** `monolithic` (default) | `scalable` (SSD: read/write/backend)
- **Storage:** `filesystem` (default, no deps) | `s3` (external MinIO)
- **Resources:** `0.25 CPU / 256M` reserved, `1 CPU / 1G` limit
- **Default retention:** 90 days

See `PRD.md` for the full design rationale.

---

## Prerequisites

The compose attaches Loki to an external Docker network called `loki_router`. This network must exist before starting Loki, and any service Loki needs to reach (MinIO, Grafana, etc) must also be attached to it.

```bash
docker network create --driver bridge loki_router
```

If you already have MinIO running on a different network, attach it:

```bash
docker network connect loki_router minio
```

---

## Quick start

```bash
# 1. Configure
cp .env.example .env
# Edit .env: at minimum LOKI_INSTANCE_NAME (and S3 creds if using s3 backend)

# 2. Create the data directory and fix ownership (uid 10001 inside container)
./scripts/init.sh

# 3. Bring it up (mode is read from COMPOSE_PROFILES in .env)
docker compose up -d

# 4. Verify
docker compose ps
curl -s http://localhost:3100/ready
```

The mode (`monolithic` | `scalable`) and backend (`filesystem` | `s3`) are controlled **entirely from `.env`** — no need to pass `--profile` or any flag in CLI.

---

## Multiple Loki instances on the same host

Each system in its own folder with its own `.env`:

```
/opt/loki/
├── system-a/
│   ├── docker-compose.yml    (symlink or copy)
│   ├── .env                  (LOKI_INSTANCE_NAME=system-a, LOKI_HTTP_PORT=3100)
│   └── data/loki/
└── system-b/
    ├── docker-compose.yml
    ├── .env                  (LOKI_INSTANCE_NAME=system-b, LOKI_HTTP_PORT=3101)
    └── data/loki/
```

Each `.env` must have:
- A unique `LOKI_INSTANCE_NAME`.
- Different `LOKI_HTTP_PORT` / `LOKI_GRPC_PORT` if they bind to the host.
- A unique `S3_BUCKET` per system (when using `s3` backend).

---

## Storage backends

### `filesystem` (default)

- Chunks, index and WAL all live in `LOKI_DATA_DIR` on the host.
- No external dependencies.
- Works only with `monolithic` mode.

### `s3` (external MinIO)

Prerequisites in MinIO:

1. Create a dedicated bucket (`loki-<instance-name>`).
2. Create a service account with read/write policy on that bucket.
3. Set `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` in `.env`.

If your endpoint uses a self-signed cert or you access it by IP, adjust `S3_INSECURE` and `S3_FORCE_PATH_STYLE` accordingly.

---

## Multi-tenant (`X-Scope-OrgID`)

- `LOKI_AUTH_ENABLED=false` (default): clients (Promtail/Alloy) **don't** send `X-Scope-OrgID`. Everything goes to the `fake` tenant.
- `LOKI_AUTH_ENABLED=true`: every request must include `X-Scope-OrgID: <name>` (e.g. `account1`). Loki separates logs per tenant.

This is **not** network security. To protect Loki from the internet, use a reverse proxy (Traefik/nginx) with auth.

---

## Required label contract

Every log line ingested by this Loki **must** carry the following labels. The provided dashboard is built around them; without them, panels will be empty.

| Label | Required | Example | Purpose |
|-------|----------|---------|---------|
| `system` | yes | `payment`, `billing`, `auth` | Business domain. |
| `service` | yes | `account-service`, `transaction-service` | Specific app within the system. |
| `instance` | yes | `1`, `2`, `account-service-prod-1` | Replica/node id. Send `1` even if there is only one. |
| `level` | yes | `info`, `warn`, `error`, `debug` | Log level. Required for the error/warning panels. |
| `env` | optional | `production`, `staging` | Environment. Useful when one Loki receives multiple environments. |

> ⚠️ Loki does not natively reject pushes for missing labels. The contract is enforced at the **client side** (Alloy/Promtail config) and surfaced via dashboard panels (logs without `system`/`service`/`instance` simply won't appear when filtering).

> ⚠️ Do **not** use high-cardinality values as labels (`request_id`, `trace_id`, `user_id`, `session_id`). Put them in the log line itself; otherwise each unique value creates a new stream and explodes Loki's index.

### Alloy example

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
      "X-Scope-OrgID" = "payment",  // tenant = system, by convention
    }
  }
}
```

### Promtail example

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

## Grafana (optional)

This stack includes an optional Grafana service with auto-provisioned Loki datasource and a starter dashboard. To enable it, uncomment in `.env`:

```bash
COMPOSE_FILE=docker-compose.yml:docker-compose.grafana.yml
GRAFANA_ADMIN_PASSWORD=changeme    # default is admin/admin
```

Then `./scripts/init.sh && docker compose up -d`. Grafana lands at http://localhost:3000.

What gets provisioned:
- **Datasource** `Loki Local` (uid `loki-${LOKI_INSTANCE_NAME}`) pointing at this instance, with `X-Scope-OrgID: ${LOKI_INSTANCE_NAME}` baked in. Alloy/Promtail must send the same value in their HTTP headers.
- **Dashboard** `Loki — Overview` with:
  - **Datasource** picker (switch between multiple Lokis if you provision more datasources).
  - **Job** and **Level** label filters (multi-value, auto-discovered).
  - **Search** textbox for free-text regex over log lines.
  - Stat panels for total / errors / warnings.
  - Time series of log volume by level.
  - Top jobs by volume (bar gauge).
  - Logs panel with everything filtered.

Per-tenant naming convention: by default the tenant equals `LOKI_INSTANCE_NAME`. Alloy/Promtail clients must send that exact value in the `X-Scope-OrgID` header. If `LOKI_AUTH_ENABLED=false`, the header is sent but ignored — useful while you're still wiring things up. To use a tenant name different from the instance name, set `LOKI_TENANT` in `.env`.

---

## Configuration reference

All variables are read from `.env`. Every value is optional — if commented out or missing, the default below is applied.

### General

| Variable | Default | Description |
|----------|---------|-------------|
| `LOKI_VERSION` | `3.7.1` | Tag of the official `grafana/loki` image. Pin to an exact version. |
| `LOKI_INSTANCE_NAME` | `default` | Unique name for this instance. Used as suffix for container_name and (by convention) as the bucket name in MinIO. |
| `COMPOSE_PROFILES` | `monolithic` | Deployment mode: `monolithic` (single container, all components) or `scalable` (read/write/backend, requires s3 backend). Native Compose variable. |
| `LOKI_DATA_DIR` | `./data/loki` | Host directory where Loki persists WAL, TSDB index, compactor working dir and (filesystem backend only) chunks. |
| `LOKI_ANALYTICS_REPORTING` | `false` | If `true`, sends usage diagnostics to Grafana Labs. Off by default. |

### Resources

| Variable | Default | Description |
|----------|---------|-------------|
| `LOKI_CPU_RESERVATION` | `0.25` | Minimum CPU guaranteed by Docker for the container. |
| `LOKI_MEMORY_RESERVATION` | `256M` | Minimum memory guaranteed by Docker for the container. |
| `LOKI_CPU_LIMIT` | `1.0` | Hard CPU ceiling. |
| `LOKI_MEMORY_LIMIT` | `1G` | Hard memory ceiling. Above this, the container is OOM-killed. |

### Network

| Variable | Default | Description |
|----------|---------|-------------|
| `LOKI_HTTP_PORT` | `3100` | Host port for Loki's HTTP API. Change if it collides with another Loki on the same host. |
| `LOKI_GRPC_PORT` | `9095` | Host port for Loki's gRPC API. |
| `LOKI_ROUTER_NETWORK` | `loki_router` | External Docker network shared with MinIO/Grafana/etc. Must exist before `up`. |

### Retention and ingestion limits

| Variable | Default | Description |
|----------|---------|-------------|
| `LOKI_RETENTION_PERIOD` | `2160h` (90d) | How long logs are kept before the compactor deletes them. |
| `LOKI_MAX_QUERY_LENGTH` | `2161h` | Maximum time range a single query can cover. Slightly above retention so queries cover the full range. |
| `LOKI_INGESTION_RATE_MB` | `4` | Sustained ingestion rate per tenant, in MB/s. |
| `LOKI_INGESTION_BURST_MB` | `6` | Burst size allowed above the sustained rate, in MB. |

### Multi-tenant

| Variable | Default | Description |
|----------|---------|-------------|
| `LOKI_AUTH_ENABLED` | `false` | If `true`, every push/query must include `X-Scope-OrgID: <name>` and Loki separates data per tenant. If `false`, all data lands in tenant `fake`. Not network auth. |

### Storage backend

| Variable | Default | Description |
|----------|---------|-------------|
| `LOKI_STORAGE_BACKEND` | `filesystem` | Where chunks live: `filesystem` (local disk, single-node only) or `s3` (external MinIO/S3, required for scalable mode). |

### Grafana (only when enabled via `COMPOSE_FILE`)

| Variable | Default | Description |
|----------|---------|-------------|
| `COMPOSE_FILE` | _(unset)_ | Set to `docker-compose.yml:docker-compose.grafana.yml` to bring Grafana up alongside Loki. |
| `GRAFANA_VERSION` | `13.0.1` | Tag of the official `grafana/grafana` image. |
| `GRAFANA_ADMIN_USER` | `admin` | Initial admin user. |
| `GRAFANA_ADMIN_PASSWORD` | `admin` | Initial admin password. **Change in production**. |
| `GRAFANA_LOG_LEVEL` | `warn` | Grafana log verbosity. |
| `GRAFANA_PORT` | `127.0.0.1:3000` | Host port for the Grafana UI. Bound to loopback by default; change to `0.0.0.0:3000` to expose on LAN. |
| `GRAFANA_LOKI_URL` | `http://loki:3100` | URL Grafana uses to reach Loki (in the shared network). |
| `GRAFANA_DATA_DIR` | `./data/grafana` | Host directory for Grafana SQLite db, plugins, etc. |
| `GRAFANA_CPU_RESERVATION` | `0.1` | Minimum CPU reserved. |
| `GRAFANA_MEMORY_RESERVATION` | `128M` | Minimum memory reserved. |
| `GRAFANA_CPU_LIMIT` | `1.0` | CPU ceiling. |
| `GRAFANA_MEMORY_LIMIT` | `512M` | Memory ceiling. |

### S3 / MinIO (only when `LOKI_STORAGE_BACKEND=s3`)

| Variable | Default | Description |
|----------|---------|-------------|
| `S3_ENDPOINT` | _(empty)_ | MinIO/S3 URL. Use `https://` when behind a TLS reverse proxy. |
| `S3_BUCKET` | _(empty)_ | Bucket dedicated to this instance. Must exist before starting Loki. |
| `S3_ACCESS_KEY` | _(empty)_ | Service account access key with read/write on the bucket. |
| `S3_SECRET_KEY` | _(empty)_ | Service account secret key. |
| `S3_REGION` | `us-east-1` | Required by the AWS SDK; MinIO ignores it. |
| `S3_FORCE_PATH_STYLE` | `true` | Use path-style URLs (`endpoint/bucket/...`). MinIO requires this. |
| `S3_INSECURE` | `false` | Set to `true` only when `S3_ENDPOINT` is `http://` (no TLS). |

---

## Operations

```bash
# Logs
docker compose logs -f loki

# Stats
docker stats $(docker compose ps -q)

# Reload config (brief API downtime, in-memory data preserved)
docker compose restart loki

# Stop
docker compose down

# Stop and DELETE all data (⚠️ destructive)
docker compose down -v
sudo rm -rf ./data/loki
```

---

## Endpoints

| Endpoint | Purpose |
|----------|---------|
| `GET /ready` | Healthcheck (200 when ready) |
| `GET /metrics` | Prometheus metrics |
| `POST /loki/api/v1/push` | Log ingest (Promtail/Alloy) |
| `GET /loki/api/v1/query_range` | Queries (Grafana) |

---

## Troubleshooting

**Loki won't start, logs show "permission denied" on `/loki`:**
```bash
sudo chown -R 10001:10001 ./data/loki
```

**`/ready` returns 503 with "ingester not ready":**
Normal for the first ~30s. If it persists, check `docker compose logs loki`.

**S3: "InvalidAccessKeyId" or "SignatureDoesNotMatch":**
- Check the credentials in `.env`.
- Confirm `S3_FORCE_PATH_STYLE=true` for MinIO.
- If endpoint is `http://`, set `S3_INSECURE=true`.

**`network loki_router declared as external, but could not be found`:**
Create it: `docker network create --driver bridge loki_router`.

**Synchronized CPU spikes across multiple Lokis:**
The default `compaction_interval=10m` runs at the same time on all instances. To stagger them, edit `config/loki-*.yaml` and give each system a different value (e.g. `11m`, `13m`).
