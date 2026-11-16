# Docker Compose base

`compose.yaml` runs the base of the platform on one host: PostgreSQL, Valkey, and the Grafana LGTM stack (OpenTelemetry Collector, Prometheus, Loki, Tempo, and Grafana). Each part is a separate container.

## Requirements

- Docker Engine with Docker Compose 2.38 or later.
- `openssl` to make passwords (optional).

## Install

1. Copy the example file: `cp .env.example .env`.
2. Protect the file: `chmod 600 .env`.
3. Replace each `change-me` value in `.env` with a new password. To make a password, run `openssl rand -base64 32`.
4. Start the base: `docker compose up -d`.
5. Examine the states: `docker compose ps`. The services `postgres`, `valkey`, `prometheus`, and `grafana` show `healthy`. The collector, Loki, and Tempo show `running`, because their images have no shell for a health check. The services `provision-postgres` and `provision-valkey` show `exited (0)`.
6. Open Grafana at `http://127.0.0.1:3000`. Log in with `GRAFANA_ADMIN_USER` and `GRAFANA_ADMIN_PASSWORD`.

Use `docker compose up -d` and not `docker compose up -d --wait` for the base. Compose 5 returns an error for `--wait` when a one-shot service exits and no other service depends on it. A service block that depends on both provisioning services (see "Add a service") works with `--wait`.

## Configuration

All settings are in `.env`. Compose reads `.env` in the project folder. The variable `CONSTELLATION_ENV_FILE` gives the same path to the two provisioning services. Keep it as `.env`.

| Variable | Default | Use |
| -------- | ------- | --- |
| `CONSTELLATION_SERVICES` | empty | Names of the platform services. Comma-separated. |
| `POSTGRES_USER`, `POSTGRES_PASSWORD` | `postgres`, none | PostgreSQL admin. |
| `POSTGRES_MAX_CONNECTIONS` | `200` | `max_connections` of PostgreSQL. |
| `VALKEY_ADMIN_PASSWORD` | none | Password of the Valkey `default` (admin) user. |
| `VALKEY_MAXMEMORY` | `256mb` | Memory limit of Valkey. |
| `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD` | `admin`, none | Grafana admin. |
| `GRAFANA_BIND`, `GRAFANA_PORT` | `127.0.0.1`, `3000` | Host IP and host port of Grafana. |
| `PROMETHEUS_RETENTION` | `15d` | Retention of metrics. |
| `LOKI_RETENTION` | `168h` | Retention of logs. |
| `TEMPO_RETENTION` | `72h` | Retention of traces. |

Each image has an exact version tag in `compose.yaml`. No image uses `latest`.

## Ports

Only Grafana publishes a host port. It uses `${GRAFANA_BIND:-127.0.0.1}:${GRAFANA_PORT:-3000}`. To reach Grafana from other hosts, set `GRAFANA_BIND` and put a TLS reverse proxy in front of it. TLS is out of scope for this repository.

Do not publish other ports. This includes the OTLP ports of the collector (4317 and 4318) and the admin port of each platform service (`:9090` with `/livez` and `/readyz`). A service in the `constellation` network reaches the collector at `http://otel-collector:4318`.

## Provisioning

`CONSTELLATION_SERVICES` has the service names, for example `identity,audit`. A name matches `^[a-z][a-z0-9_]{0,31}$`. The names `default`, `public`, `postgres`, `template0`, `template1`, and each name that starts with `pg_` are reserved. For each name `<svc>`, `.env` has `<SVC>_DB_PASSWORD` and `<SVC>_VALKEY_PASSWORD` (upper case).

Two one-shot services make the objects. They are idempotent. A second run gives the same result.

- `provision-postgres` makes the role `<svc>` and the database `<svc>` with the role as owner. It removes the `CONNECT` permission of `PUBLIC` and gives it to the role. A service cannot connect to the database of another service.
- `provision-valkey` makes the ACL user `<svc>`. The user can use the keys `<svc>:*` and the commands `+@all -@admin -@dangerous -function -script|flush -script|kill`. The script saves the users to the ACL file in the `valkey-data` volume, so they stay after a restart.

The scripts do not print passwords. A password can have any character, but a Valkey password cannot have a space. Services connect to PostgreSQL directly. Do not put a pooler in transaction mode between them, because it breaks the advisory locks of the migrations.

## Add a service

1. Add the name to `CONSTELLATION_SERVICES` in `.env`.
2. Add `<SVC>_DB_PASSWORD` and `<SVC>_VALKEY_PASSWORD` to `.env`.
3. Add a service block to `compose.yaml` (the template below).
4. Run the provisioning services: `docker compose run --rm provision-postgres` and `docker compose run --rm provision-valkey`. Then run `docker compose up -d`.

Template for a service `identity`. Replace `identity` and `IDENTITY` with the name of the service. URL-encode the password in `DATABASE__URL`.

```yaml
  identity:
    image: ghcr.io/techorionai/constellation-identity:1.2.3
    restart: unless-stopped
    depends_on:
      provision-postgres:
        condition: service_completed_successfully
      provision-valkey:
        condition: service_completed_successfully
      otel-collector:
        condition: service_started
    environment:
      IDENTITY_DATABASE__URL: postgres://identity:${IDENTITY_DB_PASSWORD_URLENCODED}@postgres:5432/identity?sslmode=disable
      IDENTITY_DATABASE__NAME: identity
      IDENTITY_VALKEY__ADDRESS: valkey:6379
      IDENTITY_VALKEY__USERNAME: identity
      IDENTITY_VALKEY__PASSWORD: ${IDENTITY_VALKEY_PASSWORD}
      IDENTITY_VALKEY__KEY_PREFIX: identity
      OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318
    networks:
      - constellation
```

Add `IDENTITY_DB_PASSWORD_URLENCODED` to `.env` with the URL-encoded form of `IDENTITY_DB_PASSWORD`.

The internal network has no TLS. With `sslmode=disable`, `constellation-platform-go` writes a `warn` log record at each start. The warning is expected on the internal network.

## Valkey

Valkey runs with AOF (`appendonly yes`) and `maxmemory-policy noeviction`. Streams must not lose events. When the memory is full, write commands return an error and Valkey does not remove keys. Set `VALKEY_MAXMEMORY` to a value that fits your data.

`valkey-server` does not run as root. A first start with an empty `valkey-data` volume writes the ACL file with the `default` user. A later start does not change the file.

## Change an admin password

PostgreSQL, Valkey, and Grafana read the admin password at the first start of an empty volume only. A change of the value in `.env` alone has no effect. Use these steps, and then change the value in `.env`.

- PostgreSQL: `docker compose exec postgres psql -U postgres -c "ALTER ROLE postgres PASSWORD '<new>'"`.
- Valkey: `docker compose exec -e REDISCLI_AUTH=<old> valkey valkey-cli ACL SETUSER default '><new>'`. Then run `ACL SAVE` the same way. Then remove the old password with `ACL SETUSER default '<old'`, where `old` is the old password.
- Grafana: `docker compose exec grafana grafana cli admin reset-admin-password <new>`.

To change the password of a service, change the two values in `.env` and run both provisioning services again (see "Add a service", step 4). Then restart the service.

## Telemetry

Services send traces, metrics, and logs with OTLP to the collector. The collector sends metrics to Prometheus, logs to Loki, and traces to Tempo. Services push metrics. Prometheus does not scrape. Grafana has the three data sources, with links between logs and traces. No container sends usage data.

## Tests

Run the tests from the repository root. They need Docker.

```sh
bash scripts/check-compose.sh        # Static checks. No container runs.
bash tests/check-compose-cases.sh    # Negative cases of the static checks.
bash scripts/smoke-test.sh           # Live containers. Takes some minutes.
```

Run `scripts/smoke-test.sh` directly on the host, not under `act`. A relative bind mount does not work under `act` with a Docker Desktop host. The script uses the project name `constellation-smoke` and the values of `tests/smoke.env`. The values in this file are for tests only. The script removes its containers and volumes at the end.

## Upgrade

Change an image tag in a release of this repository. Read the release notes of the image before you change a tag. Then run `docker compose pull` and `docker compose up -d`. Each release of this repository examines the tags.
