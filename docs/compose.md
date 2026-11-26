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
   chmod 0700 secrets
   openssl rand -base64 32 > secrets/identity-master-key
   ```

   Then set the owner and the mode of the file (see "Master key").

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
| `IDENTITY_BIND`, `IDENTITY_PORT` | `127.0.0.1`, `8080` | Host IP and host port of identity. Keep the bind on loopback unless a TLS reverse proxy runs on the same host. |
| `IDENTITY_TRUSTED_PROXIES` | empty | CIDR list of the reverse proxies in front of identity. Set it when you use a proxy (see "Identity"). |
| `IDENTITY_GOOGLE_CLIENT_ID` | empty (off) | Client ID of the Google OAuth client. Setting it turns on the login with Google. Store the client secret first (see "Upstream login"). |
| `IDENTITY_GOOGLE_ALLOWED_DOMAINS` | empty (all accounts) | Comma list of Google hosted domains that can log in. |
| `IDENTITY_MICROSOFT_CLIENT_ID` | empty (off) | Application (client) ID of the Microsoft app registration. Setting it turns on the login with Microsoft work accounts. Store the client secret first. |
| `IDENTITY_MICROSOFT_TENANT` | `organizations` | A tenant GUID (recommended) or `organizations`. The values `common` and `consumers` stop the start. |
| `IDENTITY_WEBAUTHN_RP_NAME` | `Constellation` | The name that the browser shows when a user registers a passkey. |
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

The service `identity` is the identity provider of the platform. It uses the image `ghcr.io/techorionai/constellation-identity:0.6.0`. It uses the database `identity` and the Valkey user `identity` that the provisioning services make from the name `identity` in `CONSTELLATION_SERVICES`.

### Master key

The master key encrypts the signing keys of identity in the database. Make the key file on the host before the first start:

```sh
install -d -m 0700 secrets
chmod 0700 secrets
openssl rand -base64 32 > secrets/identity-master-key
```

The command `install -d -m 0700` does not change the mode of a folder that exists. The command `chmod 0700 secrets` does.

- Set `IDENTITY_MASTER_KEY_FILE` in `.env` to the path of the file. `.env.example` has the value `./secrets/identity-master-key`.
- Set `IDENTITY_MASTER_KEY_ID` to an ID that matches `^[a-z0-9-]{1,32}$`. `.env.example` has the value `identity-1`. The ID is not a secret.
- The container user has the UID 65532. Compose mounts the file and keeps the owner and the mode of the host file.
- On Linux, give the file to the container user and make it read-only: `sudo chown 65532:65532 secrets/identity-master-key` and `chmod 0400 secrets/identity-master-key`. Then only the container user (and root) can read the key.
- Use the fallback `chmod 0444 secrets/identity-master-key` only where you cannot change the owner, for example Docker Desktop. Each user of the host who can open the file can then read the key. The mode `0700` of the folder `secrets/` is the only control. Check that the folder has this mode.
- Git ignores `secrets/`.
- Keep a copy of the key in a safe place. If the key is lost, all signing keys and secrets in the database are unreadable. This includes the client secrets of Google and Microsoft. Identity then stops at the start with a message. The operator runs `identity rotate-signing-keys --force` to make new signing keys.

### Issuer, port, and clients file

- `IDENTITY_ISSUER` is the public URL that browsers use. `.env.example` has the value `http://localhost:8080`. It must agree with `IDENTITY_BIND` and `IDENTITY_PORT`. Identity accepts an `http` issuer only for `localhost`, `127.0.0.1`, and `[::1]`.
- The public port is `${IDENTITY_BIND:-127.0.0.1}:${IDENTITY_PORT:-8080}`. The admin port `9090` is not published.
- A host other than `localhost` needs TLS. The session cookie has the flag `Secure`, and the issuer rule needs `https`. TLS is out of scope for this repository. Use a TLS reverse proxy.
- Keep `IDENTITY_BIND` on `127.0.0.1` unless a TLS reverse proxy runs on the same host. With `IDENTITY_BIND=0.0.0.0` and an `http://localhost` issuer, identity serves plain HTTP on all interfaces. Tokens and client assertions then go on the network in plain text. A port that Docker publishes also bypasses host firewalls such as `ufw`.
- With a reverse proxy, set `IDENTITY_TRUSTED_PROXIES` in `.env` to the CIDR of the proxy. Identity then uses `X-Forwarded-For` from the proxy. If you do not set it, identity sees the proxy address as the client address of all users. They then share one login lockout (50 failures in 15 minutes), and the audit log has the proxy address.
- The values of `IDENTITY_DB_PASSWORD_URLENCODED` and `IDENTITY_VALKEY_PASSWORD` are plain environment values of the container. A user of `docker inspect` can read them. Such a user has Docker access, which is almost root. The base services do the same for their admin passwords. Identity has no `_FILE` form for these values. This is a known limit.
- Identity limits the requests to its public endpoints with counters in Valkey. Valkey must be healthy. Most limits fail closed with status 503 when Valkey is down. The defaults need no setting. `IDENTITY_RATE_LIMIT__ENABLED`, `IDENTITY_RATE_LIMIT__<BUCKET>__LIMIT`, and `IDENTITY_RATE_LIMIT__<BUCKET>__WINDOW` are optional. The bucket `idp` counts the start and the callback of the upstream login. It gives 30 requests in 1 minute for one IP. Compose does not pass `IDENTITY_IDP__HTTP_TIMEOUT` (one deadline for all outbound calls of one request to a provider, default `10s`, range `1s` to `25s`). To change it, add `IDENTITY_IDP__HTTP_TIMEOUT: ${IDENTITY_IDP_HTTP_TIMEOUT:-10s}` to the identity `environment` in `compose.yaml` and set `IDENTITY_IDP_HTTP_TIMEOUT` in `.env`. Add `IDENTITY_RATE_LIMIT__*` settings in the same way.
- The limits use the client IP. Behind a proxy without `IDENTITY_TRUSTED_PROXIES`, all clients share the limits of the proxy address, also the bucket `idp`. Each trusted proxy must append the address of its peer to `X-Forwarded-For`.
- To remove the login lock of one email, run `docker compose exec identity /identity unlock-login <email>`.
- An admin with no MFA must set up TOTP or register a passkey at the next login. This rule is on by default. The Compose file does not pass `IDENTITY_MFA__REQUIRE_FOR_ADMINS` to the container, so you cannot change the rule in `.env`. The service seals the TOTP secrets with the master key of identity. After the upgrade, each admin must set up TOTP or register a passkey at once. Until then, a person who knows the password of the admin can set up the second factor.
- To remove the TOTP factor, the recovery codes, and all passkeys of a user who lost the device and the recovery codes, or a user with passkeys only (such a user has no recovery codes), run `docker compose exec identity /identity reset-mfa <email>`. Before you run it, check the identity of the requester outside the service, for example in person or by a call. After the reset, the password alone gives a login and a new second factor. The user must set up TOTP or register a passkey at once.
- Users can register passkeys on the page `/account/passkeys`. The RP ID of a passkey is the host of `IDENTITY_ISSUER`. For a local use, set `IDENTITY_ISSUER` to `http://localhost:8080`, not `http://127.0.0.1:8080`. An issuer with an IP address as host turns passkeys off. Then the hosted passkey pages give 404, and a stored passkey does not count as a second factor. A change of the issuer host makes all stored passkeys useless. Warning: do not change the issuer host to an IP address after users registered passkeys. A user with passkeys only can then log in with the password alone. An admin with passkeys only can then set up TOTP after a login with the password alone. Before you change the issuer host, tell the users to register TOTP or a second passkey. See also "Lock-out warning". The setting `IDENTITY_WEBAUTHN__ENABLED` (default `true`) turns passkeys off. The Compose file does not pass it to the container, so you cannot change it in `.env`.
- `config/identity/clients.yaml` is the clients file. It has `clients: []`. When a service needs a client, add it to this file and restart `identity`.
- The `AllowInsecureHTTP` options of the services that call identity are for local Compose only (see "Add a service"). Production uses `https` and keeps the options `false`.

### Upstream login

Identity can log users in with a Google account or a Microsoft work account. This is optional. A user links the account on the page `/account/security`, or accepts an invite with it. There is no sign-up with an upstream account. A provider is off when its client ID is empty.

**Register the app at the provider.** Use a test registration first.

- Google: make an OAuth client of the type "Web application". The scopes are `openid`, `email`, and `profile`.
- Microsoft: make an app registration with the platform "Web". Do not use "Single-page application". The sign-in audience must agree with `IDENTITY_MICROSOFT_TENANT`. The recommended form is a single tenant, with the tenant GUID in `IDENTITY_MICROSOFT_TENANT`. The second form is multitenant (organizations only), with the value `organizations`. Never allow personal accounts. The values `common` and `consumers` stop the start of identity. A single tenant app with the value `organizations` fails with the error `AADSTS50194`.
- Microsoft optional claims: in "Token configuration" of the app registration, add the optional claims `email` and `xms_edov` to the ID token. The claim `xms_edov` is in the token only when `email` is in the token. Each user needs an email (the `mail` attribute) in a verified domain of the tenant. Without the claims, an invite with Microsoft fails. The login of a linked user still works.

**Redirect URI.** Register `${IDENTITY_ISSUER}/login/oidc/<provider>/callback` at the provider. `<provider>` is `google` or `microsoft`. For example: `http://localhost:8080/login/oidc/google/callback`.

- A host other than `localhost` needs `https`.
- The provider matches the URI exactly.
- A change of `IDENTITY_ISSUER` changes the URI. Then change it at both providers.
- Microsoft ignores the port of a `localhost` URI. Google does not.
- The issuer `http://127.0.0.1:8080` is not supported. Use `http://localhost:8080`.

**Store the client secret, then set the client ID.** Identity does not start when a client ID is set and its secret is not stored. It then logs the error `identity.idp.secret_missing` with the provider name. Use this order:

1. Start the stack with no client ID.
2. Store the secret. The secret goes in through stdin. It is on no command line.

   ```sh
   read -rs S && printf '%s\n' "$S" | docker compose exec -T identity /identity set-idp-secret google
   unset S
   ```

   Use `microsoft` in place of `google` for Microsoft. The command prints `stored`. It exits with code 2 if the secret is empty, or if the provider name is wrong. `printf` is a Bash built-in, so the value is on no process command line, and it stays out of the shell history. The option `-T` is necessary, because the command reads stdin.

   If you use a file, put it in `secrets/` with the mode `0600`, use `< secrets/<file>` as the input, and remove the file after the command. Git ignores `secrets/`. A file in the work folder can go into a commit.

   Never put the secret on a command line, in `.env`, or in a file in the work folder.
3. Set the client ID in `.env` (`IDENTITY_GOOGLE_CLIENT_ID` or `IDENTITY_MICROSOFT_CLIENT_ID`). Run `docker compose up -d identity`.

If you set the client ID first, the container restarts again and again, so `docker compose exec` does not work. To recover, remove the client ID from `.env` and run `docker compose up -d identity`. Store the secret. Set the client ID again and run `docker compose up -d identity`.

**Rotate a client secret.** A provider shows a secret one time. Microsoft limits the life of a secret to 24 months and recommends less than 12 months. Record the expiry date. Microsoft recommends a certificate for production. Identity supports client secrets only. This is a known limit.

1. Make a new secret at the provider.
2. Store it with `set-idp-secret`, as above.
3. Run `docker compose restart identity`. Identity reads the new secret at the start.
4. Do a login with the provider.
5. Remove the old secret at the provider.

**Rules of identity v0.6.0.**

- Before a user links an account, and before a user removes a link, identity asks for a local factor if the user has one: the password, a TOTP code, or a passkey. A user with no local factor needs a fresh login at the provider.
- A user with no password can set a first password at the page `/account/password`. The session must be fresh. Identity writes an audit entry and sends a notice, because a password is a new login method.
- Every active user can read and remove the own links. The implicit role `identity:user` has the permission `identity:identity_link:manage_own`. The manifest of identity gives the permission. No Compose file or clients file needs a change for it.
- Identity does not trust the MFA of the provider. A user with TOTP or a passkey must still give the second factor after a login with an upstream account.
- A removal of a link ends all sessions that used the upstream login. It also revokes the personal API tokens that such a session made. API tokens that were made before `0.6.0` stay valid, because identity did not record how they were made. A user can revoke them by hand.

### Lock-out warning

A user with no login method cannot log in. A login method is a password, a passkey that identity accepts, or a link to a provider that is on.

- Before you remove a client ID, link each user to another login method, or help the user to set a password at the page `/account/password`.
- Do the same before you change the issuer host to an IP address, because passkeys then turn off.
- After each start, run `docker compose logs identity` and look for the warning `identity.idp.users_without_login_method`. It has the count of active users with no login method.
- Recovery of a user who has no login method. The user cannot log in, so the user cannot fix the problem. An invite does not work for this user, because the user has the status `active`. Identity refuses an invite for an `active` user with 409 `user_not_invited`. Use the path that fits the cause.
  - Last active admin, or no other admin can use the admin API: do the restore path first. Set the client ID again and store the secret again (see "Upstream login"), or set the issuer host back to the old host so that passkeys work. Run `docker compose up -d identity`. The admin can then log in. The admin sets a password at `/account/password`, or links a second method, before you remove the provider again. Identity gives 409 `last_admin` when you disable the last active admin, and the command `setup-link` does not work when an admin exists. Thus the disable path below is not possible for this user.
  - Other users: first try the restore path above. If you cannot restore the method, another admin does this. Disable the user (`Users_update` with `disabled` `true`). Enable the user (`Users_update` with `disabled` `false`). Identity gives the status `invited` to an enabled user that has no login method. Then send an invite (`Invites_create`). The user accepts the invite and sets a password. The disable also revokes the sessions and the API tokens of the user. An enable does not restore the API tokens. The user must make new tokens.
  - A user who has a password and lost the second factor: the operator runs `docker compose exec identity /identity reset-mfa <email>`. The command `reset-mfa` does not use the rule "last login method". It writes the log event `identity.mfa.reset_last_login_method` if the user then has no login method.

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
      # The audience of the service. Use the name of the service. Never use "identity".
      <SVC>_AUTH__AUDIENCE: <svc>
      # Local Compose only. The issuer and the JWKS URL use http here. In production, both use https and this stays false.
      <SVC>_AUTH__ALLOW_INSECURE_HTTP: "true"
      # Client values for auth/clientcred. The ID and the key ID come from the entry of the service in clients.yaml.
      <SVC>_CLIENT__ID: <client id>
      <SVC>_CLIENT__KEY_ID: <key id>
      <SVC>_CLIENT__PRIVATE_KEY_FILE: /run/secrets/<svc>_client_key
```

Give the private key of the client as a Compose secret. Never put the key in `.env` or in an `environment` value, because `docker inspect` shows it. Add this to the service block and to the top level of `compose.yaml`. Keep the key file in the folder `secrets/` with the owner of the service and the mode `0400`:

```yaml
    # In the service block:
    secrets:
      - <svc>_client_key

# At the top level:
secrets:
  <svc>_client_key:
    file: ./secrets/<svc>-client-key.pem
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

Check 5 of `scripts/check-compose.sh` requires the value `change-me` for each variable in `.env.example` that has `PASSWORD`, `SECRET`, `TOKEN`, or `KEY` in its name. Only the two exact names `IDENTITY_MASTER_KEY_FILE` and `IDENTITY_MASTER_KEY_ID` can have any value. A name with the suffix `_FILE` or `_ID` is not exempt.

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

Upgrade from identity `0.5.0` to `0.6.0`: the new version adds the database migrations `0014` and `0015`. The migrations only add objects. Read the release notes of identity `v0.6.0` and make a backup of the database before you update. The new settings of the upstream login are optional. With no client ID, identity has no upstream login.
