# constellation-deploy

Deployment files of the Constellation platform.

## Compose base

`compose.yaml` runs PostgreSQL, Valkey, and the Grafana LGTM stack (OpenTelemetry Collector, Prometheus, Loki, Tempo, and Grafana) on one host. A provisioning step makes one PostgreSQL database and role, and one Valkey ACL user, for each platform service. The first platform service is `identity`, the identity provider.

```sh
cp .env.example .env
# Replace each "change-me" value in .env.
# Make the master key of identity.
install -d -m 0700 secrets
chmod 0700 secrets
openssl rand -base64 32 > secrets/identity-master-key
# On Linux: sudo chown 65532:65532 secrets/identity-master-key && chmod 0400 secrets/identity-master-key
# Where you cannot change the owner: chmod 0444 secrets/identity-master-key (see docs/compose.md).
docker compose up -d
docker compose ps
```

See [docs/compose.md](docs/compose.md) for the configuration, the identity setup, the service template, and the steps to add a service.

## Tests

```sh
bash scripts/check-compose.sh      # Static checks
bash tests/check-compose-cases.sh  # Negative cases of the static checks
bash scripts/smoke-test.sh         # Live containers (needs Docker)
```

Lint: `yamllint --strict .`, `shellcheck` on each `*.sh` file, and `actionlint`.

CI calls the Compose workflow of `techorionai/constellation-ci`.
