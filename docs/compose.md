# Docker Compose base

`compose.yaml` runs the base of the platform on one host: PostgreSQL, Valkey, and the Grafana LGTM stack (OpenTelemetry Collector, Prometheus, Loki, Tempo, and Grafana). Each part is a separate container.

## Requirements

- Docker Engine with Docker Compose 2.38 or later.
- `openssl` to make passwords and the master key of identity.

## Install

1. Copy the example file: `cp .env.example .env`.
2. Protect the file: `chmod 600 .env`.
3. Replace each `change-me` value in `.env` with a new password. To make a password, run `openssl rand -base64 32`. The containers reject the placeholder `change-me` and each password with fewer than 12 characters, and they do not start. This includes `GRAFANA_SECRET_KEY`. Set `IDENTITY_DB_PASSWORD_URLENCODED` to the URL-encoded form of `IDENTITY_DB_PASSWORD`. A password from `openssl rand -base64 32` can have the characters `+`, `/`, and `=`, so encode it.
4. Make the master key of identity (see "Identity"):

   ```sh
   install -d -m 0700 secrets
   openssl rand -base64 32 > secrets/identity-master-key
   chmod 0444 secrets/identity-master-key
   ```

5. Start the base: `docker compose up -d`.
6. Examine the states: `docker compose ps`. The services `postgres`, `valkey`, `prometheus`, `grafana`, and `identity` show `healthy`. The collector, Loki, and Tempo show `running`, because their images have no shell for a health check. The services `provision-postgres` and `provision-valkey` show `exited (0)`.
7. Open Grafana at `http://127.0.0.1:3000`. Log in with `GRAFANA_ADMIN_USER` and `GRAFANA_ADMIN_PASSWORD`.

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
| `GRAFANA_SECRET_KEY` | none | Key that Grafana uses to encrypt the secrets in its database. A change later makes the stored data source secrets unreadable. |
| `SERVICE_DB_CONNECTION_LIMIT` | `50` | Maximum number of connections for each service role in PostgreSQL. Keep the number of services times this value lower than `POSTGRES_MAX_CONNECTIONS`. |
| `GRAFANA_BIND`, `GRAFANA_PORT` | `127.0.0.1`, `3000` | Host IP and host port of Grafana. |
| `IDENTITY_DB_PASSWORD`, `IDENTITY_DB_PASSWORD_URLENCODED`, `IDENTITY_VALKEY_PASSWORD` | none | Database and Valkey passwords of identity. The second value is the URL-encoded form of the first. |
| `IDENTITY_ISSUER` | none | Public URL of identity, as browsers use it. It must agree with `IDENTITY_BIND` and `IDENTITY_PORT`. |
| `IDENTITY_MASTER_KEY_FILE` | none | Path of the master key file on the host. |
| `IDENTITY_MASTER_KEY_ID` | none | ID of the master key. It is not a secret. |
| `IDENTITY_BIND`, `IDENTITY_PORT` | `127.0.0.1`, `8080` | Host IP and host port of identity. |
| `PROMETHEUS_RETENTION` | `15d` | Retention of metrics. |
| `LOKI_RETENTION` | `168h` | Retention of logs. |
| `TEMPO_RETENTION` | `72h` | Retention of traces. |

Each image has an exact version tag in `compose.yaml`. No image uses `latest`.

Each container has `no-new-privileges` and `cap_drop: [ALL]`. `postgres` and `valkey` add only the capabilities that their image entrypoints need to change the owner of the data folder and to start the server as a non-root user. No container has a resource limit. Set one for your host if you need it.

Grafana does not send requests to third parties. The news feed, Gravatar, the plugin admin page, and the feedback links are off.

## Ports

Grafana and identity publish a host port. Grafana uses `${GRAFANA_BIND:-127.0.0.1}:${GRAFANA_PORT:-3000}`. Identity uses `${IDENTITY_BIND:-127.0.0.1}:${IDENTITY_PORT:-8080}` for its public port. To reach them from other hosts, set the bind variable and put a TLS reverse proxy in front. Identity needs TLS for a host other than `localhost` (see "Identity"). TLS is out of scope for this repository.

Do not publish other ports. This includes the OTLP ports of the collector (4317 and 4318) and the admin port of each platform service (`:9090` with `/livez` and `/readyz`). A service in the `services` network reaches the collector at `http://otel-collector:4318`.

## Networks

The base has two networks.

- `services` has `postgres`, `valkey`, the two provisioning services, `otel-collector`, `identity`, and each later platform service.
- `observability` has `otel-collector`, `prometheus`, `loki`, `tempo`, and `grafana`.

Only the collector is on both networks. A platform service cannot reach Loki, Tempo, or Prometheus, so it cannot read the telemetry of other services. The observability containers cannot reach PostgreSQL or Valkey.

Limit: Loki, Tempo, Prometheus, and the collector have no authentication. A platform service can still send false telemetry to the collector, also under the `service.name` of another service. Do not trust the `service.name` of a record as proof of its source.

## Identity

The service `identity` is the identity provider of the platform. It uses the image `ghcr.io/techorionai/constellation-identity:0.1.0`. It uses the database `identity` and the Valkey user `identity` that the provisioning services make from the name `identity` in `CONSTELLATION_SERVICES`.

### Master key

The master key encrypts the signing keys of identity in the database. Make the key file on the host before the first start:

```sh
install -d -m 0700 secrets
openssl rand -base64 32 > secrets/identity-master-key
chmod 0444 secrets/identity-master-key
```

- Set `IDENTITY_MASTER_KEY_FILE` in `.env` to the path of the file. The default value is `./secrets/identity-master-key`.
- Set `IDENTITY_MASTER_KEY_ID` to an ID that matches `^[a-z0-9-]{1,32}$`. The default value is `identity-1`. The ID is not a secret.
- The container user has the UID 65532. Compose mounts the file and keeps the owner and the mode of the host file. Thus the file has the mode `0444`. The folder `secrets/` has the mode `0700`, so other users of the host cannot open the file. Git ignores `secrets/`.
- Keep a copy of the key in a safe place. If the key is lost, all signing keys and secrets in the database are unreadable. Identity then stops at the start with a message. The operator runs `identity rotate-signing-keys --force` to make new signing keys.

### Issuer, port, and clients file

- `IDENTITY_ISSUER` is the public URL that browsers use. The default is `http://localhost:8080`. It must agree with `IDENTITY_BIND` and `IDENTITY_PORT`. Identity accepts an `http` issuer only for `localhost`, `127.0.0.1`, and `[::1]`.
- The public port is `${IDENTITY_BIND:-127.0.0.1}:${IDENTITY_PORT:-8080}`. The admin port `9090` is not published.
- A host other than `localhost` needs TLS. The session cookie has the flag `Secure`, and the issuer rule needs `https`. TLS is out of scope for this repository. Use a TLS reverse proxy.
- `config/identity/clients.yaml` is the clients file. It has `clients: []`. When a service needs a client, add it to this file and restart `identity`.
- The `AllowInsecureHTTP` options of the services that call identity are for local Compose only (see "Add a service"). Production uses `https` and keeps the options `false`.

### First admin

At the first start, identity writes one log record with the message `identity: first-admin setup link pending`. The record says that a setup link exists. The log never has the link, because a person who can read the log could take over the install. To get the link, run:

```sh
docker compose exec identity /identity setup-link
```

The command prints the link and deletes the earlier unused links. Run it again to get a new link. If an admin exists, it prints an error. Do not put the link in a log, a ticket, or a chat.

## Provisioning

`CONSTELLATION_SERVICES` has the service names, for example `identity,audit`. A name matches `^[a-z][a-z0-9_]{0,31}$`. The names `default`, `public`, `postgres`, `template0`, `template1`, and each name that starts with `pg_` are reserved. For each name `<svc>`, `.env` has `<SVC>_DB_PASSWORD` and `<SVC>_VALKEY_PASSWORD` (upper case).

Two one-shot services make the objects. They are idempotent. A second run gives the same result.

- `provision-postgres` makes the role `<svc>` and the database `<svc>` with the role as owner. It removes the `CONNECT` permission of `PUBLIC` and gives it to the role. A service cannot connect to the database of another service. The script also removes `CONNECT` and `TEMP` of `PUBLIC` on the databases `postgres` and `template1`, and it sets `CONNECTION LIMIT` of each role to `SERVICE_DB_CONNECTION_LIMIT`.
- `provision-valkey` makes the ACL user `<svc>`. The user can use the keys `<svc>:*` and the commands `+@all -@admin -@dangerous -@scripting -function -scan -randomkey -dbsize -memory`. Valkey does not filter `SCAN`, `RANDOMKEY`, `DBSIZE`, and `MEMORY` by key pattern, so they would show the key names of other services. A script (`EVAL`) can block Valkey for all services, so scripts are off. The script saves the users to the ACL file in the `valkey-data` volume, so they stay after a restart. The ACL file has the SHA-256 hash of each password, not the password.

The scripts do not print passwords, and they do not put passwords on a command line. The scripts reject the placeholder `change-me`, a password with fewer than 12 characters, and a Valkey password with white space, before they change anything. Services connect to PostgreSQL directly. Do not put a pooler in transaction mode between them, because it breaks the advisory locks of the migrations.

## Add a service

1. Add the name to `CONSTELLATION_SERVICES` in `.env`.
2. Add `<SVC>_DB_PASSWORD` and `<SVC>_VALKEY_PASSWORD` to `.env`.
3. Add a service block to `compose.yaml` (the template below).
4. Run the provisioning services: `docker compose run --rm provision-postgres` and `docker compose run --rm provision-valkey`. Then run `docker compose up -d`. Use `docker compose run --rm` because `docker compose up -d` does not start an exited one-shot container again when its configuration did not change.

Template for a service `identity`. Use the exact version tag of the image in place of `<version>` (for example `0.1.0`). Replace `identity` and `IDENTITY` with the name of the service. URL-encode the password in `DATABASE__URL`. A platform service joins the `services` network only. Add the same hardening as the base services.

```yaml
  identity:
    image: ghcr.io/techorionai/constellation-identity:<version>
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
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    networks:
      - services
```

Values for a service that calls identity. Add the lines that the service needs to its `environment`. Replace `<SVC>` with the upper case name of the service.

```yaml
      # A service that gets tokens with auth/clientcred of platform-go.
      <SVC>_CLIENT__ISSUER: ${IDENTITY_ISSUER}
      <SVC>_CLIENT__TOKEN_URL: http://identity:8080/oauth/token
      # Local Compose only. The issuer and the token URL use http here. In production, both use https and this stays false.
      <SVC>_CLIENT__ALLOW_INSECURE_HTTP: "true"
      # A service that calls the identity API with clients/identity of platform-go.
      <SVC>_IDENTITY__URL: http://identity:8080
      # Local Compose only. In production, the URL uses https and this stays false.
      <SVC>_IDENTITY__ALLOW_INSECURE_HTTP: "true"
      # A service that verifies tokens with auth/jwt of platform-go.
      <SVC>_AUTH__ISSUER: ${IDENTITY_ISSUER}
      <SVC>_AUTH__JWKS_URL: http://identity:8080/.well-known/jwks.json
      # Local Compose only. The issuer and the JWKS URL use http here. In production, both use https and this stays false.
      <SVC>_AUTH__ALLOW_INSECURE_HTTP: "true"
```

Each of the three `ALLOW_INSECURE_HTTP` options is necessary in local Compose. The libraries return an error at the start if a URL does not use `https` and the option is not `true`. The libraries do not follow redirects. The `identity` service does not need these options. It sets its own option from the loopback rule of `IDENTITY_ISSUER`. A client assertion for identity has the issuer `IDENTITY_ISSUER` as `aud`, and not the token URL.

Add `IDENTITY_DB_PASSWORD_URLENCODED` to `.env` with the URL-encoded form of `IDENTITY_DB_PASSWORD`.

The internal network has no TLS. With `sslmode=disable`, `constellation-platform-go` writes a `warn` log record at each start. The warning is expected on the internal network.

## Valkey

Valkey runs with AOF (`appendonly yes`) and `maxmemory-policy noeviction`. Streams must not lose events. When the memory is full, write commands return an error and Valkey does not remove keys. Set `VALKEY_MAXMEMORY` to a value that fits your data.

`valkey-server` does not run as root. A first start with an empty `valkey-data` volume writes the ACL file with the `default` user and the SHA-256 hash of `VALKEY_ADMIN_PASSWORD`. A later start does not change the file. `provision-valkey` always runs `ACL SAVE`, also with no service, so an old ACL file with a plain text password changes to a hash.

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

Check 5 of `scripts/check-compose.sh` requires the value `change-me` for each variable in `.env.example` that has `PASSWORD`, `SECRET`, `TOKEN`, or `KEY` in its name. A name that ends in `_FILE` or `_ID` (for example `IDENTITY_MASTER_KEY_FILE` and `IDENTITY_MASTER_KEY_ID`) can have any value. The suffix must be exact.

Run `scripts/smoke-test.sh` directly on the host, not under `act`. A relative bind mount does not work under `act` with a Docker Desktop host. The script uses the project name `constellation-smoke` and the values of `tests/smoke.env`. The values in this file are for tests only. The script removes its containers and volumes at the end.

### Test U11: clone on Windows with `autocrlf`

This test shows that `.gitattributes` keeps LF line endings in the shell files when Git converts line endings. Do it on Windows, or on any host with this setting.

1. Clone the repository into a new folder with the setting: `git clone -c core.autocrlf=true <repository URL> <new folder>`.
2. Go to the new folder and select the branch to test: `git switch <branch>`.
3. Run `bash scripts/check-compose.sh`. Expected result: `check-compose: all checks passed`. Check 7 fails if a `*.sh` file has a CR character.
4. Run `bash tests/check-compose-cases.sh`. Expected result: `check-compose-cases: all cases passed`.
5. Remove the new folder.

## Upgrade

Change an image tag in a release of this repository. Read the release notes of the image before you change a tag. Then run `docker compose pull` and `docker compose up -d`. Each release of this repository examines the tags.
