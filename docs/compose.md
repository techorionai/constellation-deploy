# Docker Compose base

`compose.yaml` runs the base of the platform on one host: PostgreSQL, Valkey, and the Grafana LGTM stack (OpenTelemetry Collector, Prometheus, Loki, Tempo, and Grafana). Each part is a separate container. It also runs the platform services identity, events, audit, and helpdesk.

## Requirements

- Docker Engine with Docker Compose 2.38 or later.
- `openssl` to make passwords, the master key of identity, and the client keys of services.

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

5. Make the client keys of the events, audit, and helpdesk services and the clients file of identity (see "Service clients"). Run this step before `docker compose up -d`. Without the clients file, identity does not start, and Docker makes no directory at the missing path.

   ```sh
   bash scripts/new-service-client.sh events
   bash scripts/new-service-client.sh audit
   bash scripts/new-service-client.sh helpdesk events:producer
   ```

   Then set the owner of the key as the script prints (`sudo chown 65532:65532 secrets/events-client-key.pem secrets/audit-client-key.pem secrets/helpdesk-client-key.pem`). On Docker Desktop, use the fallback in "Service clients".

6. Start the base: `docker compose up -d`.
7. Examine the states: `docker compose ps`. The services `postgres`, `valkey`, `prometheus`, `grafana`, `identity`, `events`, `audit`, and `helpdesk` show `healthy`. The collector, Loki, and Tempo show `running`, because their images have no shell for a health check. The services `provision-postgres` and `provision-valkey` show `exited (0)`.
8. Open Grafana at `http://127.0.0.1:3000`. Log in with `GRAFANA_ADMIN_USER` and `GRAFANA_ADMIN_PASSWORD`.

Use `docker compose up -d` and not `docker compose up -d --wait` for the base. Compose 5 returns an error for `--wait` when a one-shot service exits and no other service depends on it. A service block that depends on both provisioning services (see "Add a service") works with `--wait`.

## Configuration

All settings are in `.env`. Compose reads `.env` in the project folder. The variable `CONSTELLATION_ENV_FILE` gives the same path to the two provisioning services. Keep it as `.env`.

| Variable | Default | Use |
| -------- | ------- | --- |
| `CONSTELLATION_SERVICES` | empty | Names of the platform services. Comma-separated. |
| `POSTGRES_USER`, `POSTGRES_PASSWORD` | `postgres`, none | PostgreSQL admin. |
| `POSTGRES_MAX_CONNECTIONS` | `250` | `max_connections` of PostgreSQL. |
| `VALKEY_ADMIN_PASSWORD` | none | Password of the Valkey `default` (admin) user. |
| `VALKEY_MAXMEMORY` | `256mb` | Memory limit of Valkey. See "Valkey" for the sizing rules. |
| `AUDIT_STREAM_RETENTION` | `24h` | Age limit of the audit streams of identity, events, and the helpdesk. See "Audit stream retention". |
| `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD` | `admin`, none | Grafana admin. |
| `GRAFANA_SECRET_KEY` | none | Key that Grafana uses to encrypt the secrets in its database. A change later makes the stored data source secrets unreadable. |
| `SERVICE_DB_CONNECTION_LIMIT` | `50` | Maximum number of connections for each service role in PostgreSQL. Keep the number of services times this value lower than `POSTGRES_MAX_CONNECTIONS`. |
| `GRAFANA_BIND`, `GRAFANA_PORT` | `127.0.0.1`, `3000` | Host IP and host port of Grafana. |
| `IDENTITY_DB_PASSWORD`, `IDENTITY_DB_PASSWORD_URLENCODED`, `IDENTITY_VALKEY_PASSWORD` | none | Database and Valkey passwords of identity. The second value is the URL-encoded form of the first. |
| `IDENTITY_ISSUER` | none | Public URL of identity, as browsers use it. It must agree with `IDENTITY_BIND` and `IDENTITY_PORT`. |
| `IDENTITY_MASTER_KEY_FILE` | none | Path of the master key file on the host. |
| `IDENTITY_MASTER_KEY_ID` | none | ID of the master key. It is not a secret. |
| `IDENTITY_CLIENTS_PATH` | `./secrets/identity-clients.yaml` | Path of the identity clients file on the host (see "Service clients"). |
| `EVENTS_DB_PASSWORD`, `EVENTS_DB_PASSWORD_URLENCODED`, `EVENTS_VALKEY_PASSWORD` | none | Database and Valkey passwords of the events service. The second value is the URL-encoded form of the first. |
| `EVENTS_CLIENT_KEY_FILE` | none | Path of the client key file of the events service on the host. |
| `EVENTS_CLIENT_KEY_ID` | none | ID of the client key. It is not a secret. |
| `AUDIT_DB_PASSWORD`, `AUDIT_DB_PASSWORD_URLENCODED`, `AUDIT_VALKEY_PASSWORD` | none | Database and Valkey passwords of the audit service. The second value is the URL-encoded form of the first. |
| `AUDIT_CLIENT_KEY_FILE` | none | Path of the client key file of the audit service on the host. |
| `AUDIT_CLIENT_KEY_ID` | none | ID of the client key. It is not a secret. |
| `HELPDESK_DB_PASSWORD`, `HELPDESK_DB_PASSWORD_URLENCODED`, `HELPDESK_VALKEY_PASSWORD` | none | Database and Valkey passwords of the helpdesk. The second value is the URL-encoded form of the first. |
| `HELPDESK_CLIENT_KEY_FILE`, `HELPDESK_CLIENT_KEY_ID` | none | Path of the client key file of the helpdesk on the host, and the ID of the key. The ID is not a secret. |
| `HELPDESK_BIND`, `HELPDESK_PORT` | `127.0.0.1`, `8081` | Host IP and host port of the helpdesk. Keep the bind on loopback unless a TLS reverse proxy runs on the same host. |
| `HELPDESK_TRUSTED_PROXIES` | empty | CIDR list of the reverse proxies in front of the helpdesk. Set it when you use a proxy (see "Helpdesk service"). |
| `HELPDESK_PUBLIC_BASE_URL` | none | Public URL of the helpdesk, for example `http://localhost:8081`. It has no path and no `/` at the end. A host other than `localhost` needs `https://`. The MCP resource URL and the link templates use it. |
| `HELPDESK_MCP_ALLOWED_ORIGINS` | empty | Origins that the MCP endpoint accepts, with a comma between them. Server clients send no `Origin` header, so the empty value is correct for them. |
| `AUDIT_STREAM_READER` | `audit` | The one service user that reads the audit streams (see "Audit stream ACL"). It must be in `CONSTELLATION_SERVICES`. |
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

Grafana, identity, and the helpdesk publish a host port. Grafana uses `${GRAFANA_BIND:-127.0.0.1}:${GRAFANA_PORT:-3000}`. Identity uses `${IDENTITY_BIND:-127.0.0.1}:${IDENTITY_PORT:-8080}` for its public port. The helpdesk uses `${HELPDESK_BIND:-127.0.0.1}:${HELPDESK_PORT:-8081}` for its public port. MCP clients and API clients of a person must reach the helpdesk. To reach these services from other hosts, set the bind variable and put a TLS reverse proxy in front. Identity needs TLS for a host other than `localhost` (see "Identity"). TLS is out of scope for this repository.

Do not publish other ports. This includes the OTLP ports of the collector (4317 and 4318) and the admin port of each platform service (`:9090` with `/livez` and `/readyz`). A service in the `services` network reaches the collector at `http://otel-collector:4318`.

## Networks

The base has two networks.

- `services` has `postgres`, `valkey`, the two provisioning services, `otel-collector`, `identity`, `events`, and each later platform service.
- `observability` has `otel-collector`, `prometheus`, `loki`, `tempo`, and `grafana`.

Only the collector is on both networks. A platform service cannot reach Loki, Tempo, or Prometheus, so it cannot read the telemetry of other services. The observability containers cannot reach PostgreSQL or Valkey.

Limit: Loki, Tempo, Prometheus, and the collector have no authentication. A platform service can still send false telemetry to the collector, also under the `service.name` of another service. Do not trust the `service.name` of a record as proof of its source.

## Identity

The service `identity` is the identity provider of the platform. It uses the image `ghcr.io/techorionai/constellation-identity:0.9.1`. It uses the database `identity` and the Valkey user `identity` that the provisioning services make from the name `identity` in `CONSTELLATION_SERVICES`.

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
- The limits use the client IP. Behind a proxy without `IDENTITY_TRUSTED_PROXIES`, all clients share the limits of the proxy address, also the bucket `idp` and the bucket `token_denied`. The gate for denied audit entries stays on when `IDENTITY_RATE_LIMIT__ENABLED=false`. Each trusted proxy must append the address of its peer to `X-Forwarded-For`.
- To remove the login lock of one email, run `docker compose exec identity /identity unlock-login <email>`.
- An admin with no MFA must set up TOTP or register a passkey at the next login. This rule is on by default. The Compose file does not pass `IDENTITY_MFA__REQUIRE_FOR_ADMINS` to the container, so you cannot change the rule in `.env`. The service seals the TOTP secrets with the master key of identity. After the upgrade, each admin must set up TOTP or register a passkey at once. Until then, a person who knows the password of the admin can set up the second factor.
- To remove the TOTP factor, the recovery codes, and all passkeys of a user who lost the device and the recovery codes, or a user with passkeys only (such a user has no recovery codes), run `docker compose exec identity /identity reset-mfa <email>`. Before you run it, check the identity of the requester outside the service, for example in person or by a call. After the reset, the password alone gives a login and a new second factor. The user must set up TOTP or register a passkey at once.
- Users can register passkeys on the page `/account/passkeys`. The RP ID of a passkey is the host of `IDENTITY_ISSUER`. For a local use, set `IDENTITY_ISSUER` to `http://localhost:8080`, not `http://127.0.0.1:8080`. An issuer with an IP address as host turns passkeys off. Then the hosted passkey pages give 404, and a stored passkey does not count as a second factor. A change of the issuer host makes all stored passkeys useless. Warning: do not change the issuer host to an IP address after users registered passkeys. A user with passkeys only can then log in with the password alone. An admin with passkeys only can then set up TOTP after a login with the password alone. Before you change the issuer host, tell the users to register TOTP or a second passkey. See also "Lock-out warning". The setting `IDENTITY_WEBAUTHN__ENABLED` (default `true`) turns passkeys off. The Compose file does not pass it to the container, so you cannot change it in `.env`.
- `secrets/identity-clients.yaml` is the clients file. The script `scripts/new-service-client.sh` writes it (see "Service clients"). Identity reads it only at the start, so restart `identity` after each change.
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

## Events service

The service `events` is the events service of the platform. It uses the image `ghcr.io/techorionai/constellation-events:0.2.1`, the database `events`, and the Valkey user `events`. It has no published port. Only services on the network `services` call it. Its admin port `9090` is not published.

- The events service is the first service client in Compose. It gets tokens from identity with a client key (see "Service clients"). It reads the private key as the Compose secret `events_client_key` from the file `EVENTS_CLIENT_KEY_FILE`.
- It starts after identity is healthy. It is ready only after it publishes its manifest to identity with a client credentials token. If `readyz` does not give 200, examine `EVENTS_CLIENT_KEY_ID` and the clients file first.
- The events service has no role. The implicit role `identity:service` lets it publish its manifest.
- Compose sets the three `ALLOW_INSECURE_HTTP` options of the service to `true`, because the internal network has no TLS. The audience `events` is set in the code of the service.
- The Grafana alert rule for the consumer lag and the dashboards are out of scope. The service sends the lag metric.

## Event stream ACL

`provision-valkey` gives each Valkey user two selectors for the event streams. The text is the same as `streams/valkey.ACLSelectors` of `constellation-platform-go`.

- `(~events.stream:<svc> +xadd +xtrim)` lets a service write and trim only its own stream.
- `(~events.stream:* +xreadgroup +xack +xautoclaim +xpending +xinfo|groups +xinfo|stream +xinfo|consumers +xgroup|create +xgroup|createconsumer +xgroup|delconsumer +xrange)` lets a service read events, acknowledge them, and manage its consumers on each stream.

All service users get the selectors, also `identity` and `events`. A service writes events only through its own outbox, so its own stream is the only write target.

The stream key prefix is `events.stream:`. It has a dot. A service name cannot have a dot, so the pattern `<svc>:*` of the root rule never matches a stream key.

Limit: the ACL cannot isolate consumer groups. A service can acknowledge or claim the messages of the group of another service on any stream. It can delete a consumer of another group, and the pending entries of that consumer go away. It can make a group, or an empty stream with `MKSTREAM`. It cannot write or trim the stream of another app, and it cannot delete a stream.

An existing install gets the selectors after `docker compose run --rm provision-valkey`.

## Audit service

The service `audit` is the audit service of the platform. It uses the image `ghcr.io/techorionai/constellation-audit:0.2.0`, the database `audit`, and the Valkey user `audit`. It has no published port. Only services on the network `services` call it. Its API port `8080` and its admin port `9090` are not published.

- It is a service client with no role. It reads the private key as the Compose secret `audit_client_key` from the file `AUDIT_CLIENT_KEY_FILE`. It is ready only after it publishes its manifest to identity. If `readyz` does not give 200, examine `AUDIT_CLIENT_KEY_ID` and the clients file first.
- The manifest of the audit service has the role `reader`. Identity makes the role `audit:reader`, which gives the permission `audit:log:read`. Give this role to the person or the service that searches and exports audit entries.
- Pool rule: the service needs `AUDIT_DATABASE__MAX_CONNS` of at least `4 + 2 x AUDIT_EXPORT__CONCURRENCY`. The default concurrency is 2, so the minimum is 8. `compose.yaml` sets `AUDIT_DATABASE__MAX_CONNS` to 8. If you set a higher `AUDIT_EXPORT__CONCURRENCY`, also set a higher `AUDIT_DATABASE__MAX_CONNS`. Else the service stops with a configuration error. The value must stay lower than `SERVICE_DB_CONNECTION_LIMIT`.
- `AUDIT_HTTP__TRUSTED_PROXIES` stays empty in `compose.yaml`, because the service has no proxy. If a caller that is not a proxy could send forwarded headers, the caller could write a false IP address into its own export entry. If you add a reverse proxy in front of the audit service, set `AUDIT_HTTP__TRUSTED_PROXIES` to the CIDR of the proxy.
- The images of identity `0.9.1` and events `0.2.1` write audit entries to the Valkey streams `audit.stream:identity` and `audit.stream:events`. See "Audit stream retention".

## Helpdesk service

The service `helpdesk` keeps customers and tickets. It uses the image `ghcr.io/techorionai/constellation-helpdesk:0.2.0`, the database `helpdesk`, and the Valkey user `helpdesk`. It publishes its API port `8080` as `${HELPDESK_BIND:-127.0.0.1}:${HELPDESK_PORT:-8081}`. The admin port `9090` is not published.

- The helpdesk is a service client, as the events service is (see "Service clients"). Make its key with `bash scripts/new-service-client.sh helpdesk events:producer`. The role `events:producer` lets the helpdesk register its event types. The helpdesk reads the private key as the Compose secret `helpdesk_client_key` from the file `HELPDESK_CLIENT_KEY_FILE`.
- It starts after identity and events are healthy. It is ready only after it publishes its event types and its manifest to the events service. If `readyz` does not give 200, examine `HELPDESK_CLIENT_KEY_ID` and the clients file first.
- The helpdesk checks a token with the keys of identity. For an opaque token, it calls the introspection endpoint at `http://identity:8080/oauth/introspect`. `compose.yaml` sets this URL, because the default URL comes from the issuer, which is not the address in the Compose network.
- The manifest of the helpdesk has the roles `support_agent` (all four scopes) and `viewer` (the two read scopes). Identity makes the roles `helpdesk:support_agent` and `helpdesk:viewer`. Give a role to a person or to a service with the operation `UserRoles_assign` of identity, or in the clients file for a service client.
- The audience of a token for the helpdesk is `helpdesk`. A token of another audience gives 401. A token with too few scopes gives 403.
- `HELPDESK_TRUSTED_PROXIES` is the CIDR list of the reverse proxies in front of the helpdesk. If you use a proxy and do not set it, the helpdesk sees the address of the proxy as the client address of all callers, and the audit entries have the proxy address. Each trusted proxy must append the address of its peer to `X-Forwarded-For`.
- Keep `HELPDESK_BIND` on `127.0.0.1` unless a TLS reverse proxy runs on the same host. With `HELPDESK_BIND=0.0.0.0`, the helpdesk serves plain HTTP on all interfaces, and tokens go on the network in plain text. A port that Docker publishes also bypasses host firewalls such as `ufw`.
- The helpdesk pool has 8 connections (`HELPDESK_DATABASE__MAX_CONNS`). The role limit is `SERVICE_DB_CONNECTION_LIMIT`.
- The helpdesk has an MCP server. The endpoint is `POST /mcp` on the helpdesk port. The metadata of the protected resource is at `GET /.well-known/oauth-protected-resource/mcp`. A client asks identity for a token with the parameter `audience=helpdesk`. Identity does not support the RFC 8707 parameter `resource`. The tools check the scopes of the token. A token with too few scopes gives 403 with the code `insufficient_scope`.
- `HELPDESK_PUBLIC_BASE_URL` is required. An install that is not local must use an `https://` address with no path and no `/` at the end. The helpdesk does not start with a value that breaks this rule.
- `HELPDESK_MCP_ALLOWED_ORIGINS` is empty by default. A request with no `Origin` header is always accepted. Server clients send no `Origin` header.
- Bifrost settings (roadmap item R20): set the connection type to Streamable HTTP and the URL to `<HELPDESK_PUBLIC_BASE_URL>/mcp`. Set `auth_type` to `none` and `allowed_extra_headers` to `["authorization"]`. Send the header `Authorization: Bearer <token>` with the audience `helpdesk`.
- The smoke test makes the client `smoke_helpdesk` with the roles `helpdesk:support_agent` and `events:reader`. It gets a token with a `private_key_jwt` assertion and creates a customer and a ticket with the REST API and with the MCP endpoint (checks M1 to M8). Then it examines the audit entry in the audit database and the event types in the event catalog.

## Audit stream retention

Identity, events, and the helpdesk trim their audit stream by age. `compose.yaml` sets `IDENTITY_RETENTION__AUDIT_STREAM__PERIOD`, `EVENTS_RETENTION__AUDIT_STREAM__PERIOD`, and `HELPDESK_RETENTION__AUDIT_STREAM__PERIOD` to `AUDIT_STREAM_RETENTION`. The default is `24h`. The image default is `168h`.

- The trim also deletes entries that the audit service did not read. If the audit service stops for longer than the period, the platform loses audit entries without a sign. Set `AUDIT_STREAM_RETENTION` to a value that is longer than the longest stop of the audit service. After a stop, examine the audit service and make it read the streams before the period ends.
- A short period keeps the streams small. Identity writes a `denied` audit entry for each failed request to `/oauth/token`. An unauthenticated caller can make these entries. Identity `0.9.0` and later limit them with four buckets. A request of an unauthenticated caller goes through `token_denied` (30 in 1 minute for each IP), `token_denied_daily` (1000 in 24 hours for each IP), and `token_denied_global` (100000 in 24 hours). A request of a client that authenticated goes through `token_denied` and `token_denied_client` (600 in 1 hour for each client ID). The counter `identity.audit.denied_dropped` counts the dropped entries, with the `reason` values `rate_limit_token_denied`, `rate_limit_token_denied_daily`, `rate_limit_token_denied_global`, `rate_limit_token_denied_client`, `rate_limit_admin_denied`, `rate_limit_admin_denied_daily`, and `fallback_limit`. Watch it in Grafana. An attacker can use up the global bucket and stop the denied token entries of unauthenticated callers for 24 hours. The denied token entries of authenticated clients still pass. Behind a proxy without `IDENTITY_TRUSTED_PROXIES`, all clients share one `token_denied` bucket. See "Valkey" for the sizing rules.
- The outbox tables of identity and events keep their image default of `168h`. A row that is not published stays.

## Audit stream ACL

The text of the selectors is from `constellation-platform-go` `v0.9.0` and decision D12 of `constellation-platform-go#29`. The trusted set `audit.apps` lists the audit apps. Only `provision-valkey` writes it, as the admin user. It registers each name of `CONSTELLATION_SERVICES` and deletes the other names. A producer cannot write `audit.apps`. The reader lists it with `SSCAN` and has no write command. No selector has `+srem`.

`provision-valkey` gives each Valkey user one selector to write audit entries. `(~audit.stream:<svc> +xadd +xtrim)` lets a service write and trim only its own audit stream. It is the same as `AuditProducerSelectors(app)`. No selector gives access to the old set `audit.streams`.

Only the user that `AUDIT_STREAM_READER` names also gets two reader selectors. The default is `audit`.

- `(~audit.stream:* +xreadgroup +xack +xautoclaim +xpending +xinfo|groups +xinfo|stream +xinfo|consumers +xgroup|create +xgroup|createconsumer +xgroup|delconsumer +xrange)` lets the reader read and acknowledge entries on each audit stream.
- `(~audit.apps +sscan)` lets the reader list the trusted set with `SSCAN`. The ACL does not allow `SMEMBERS`.

`AUDIT_STREAM_READER` must be in `CONSTELLATION_SERVICES` and must follow the name rule. `provision/valkey.sh` checks this before it changes anything. A service that is not the reader cannot read an audit stream or list the set.

Limits: a producer cannot add a name to `audit.apps`. No producer can write `audit.streams`, so a producer cannot use Valkey memory through that set. An older set `audit.streams` can stay in Valkey after the upgrade to `v0.6.0`. See "Upgrade from v0.5.0 to v0.6.0" for the optional delete. The ACL cannot isolate consumer groups on the audit streams, as on the event streams.

An existing install gets the selectors after `docker compose run --rm provision-valkey`.

## Service clients

A platform service that gets tokens from identity needs a client entry in the clients file of identity and a private key. The script `scripts/new-service-client.sh` makes both.

```sh
bash scripts/new-service-client.sh [--secrets-dir DIR] [--clients-file FILE] [--kid KID] [--rotate] <svc> [role ...]
```

- `<svc>` is the name of the service. The script refuses the name `identity` and each name that `provision/valkey.sh` refuses.
- A role has the form `<app>:<role>`, for example `events:producer`.
- The script makes an EC P-256 private key (PKCS #8 PEM) as `<secrets dir>/<svc>-client-key.pem` with the mode `0400`. It does not overwrite a key file. The default key ID is `<svc>-1`. `--kid` sets another ID.
- The script computes the public JWK and adds the client entry to the clients file. The default clients file is `./secrets/identity-clients.yaml`. `--clients-file` sets another path. The script does not read `.env`. If `IDENTITY_CLIENTS_PATH` has another value, give the same path with `--clients-file`.
- The clients file can be in one of three forms: no file, a file with the line `clients: []`, or a file with the line `clients:` and block list entries that start with `  - id: `. The script refuses each other form, for example a flow list, and changes nothing. It refuses a client `id` that exists. The script writes a temporary file in the same folder and renames it, so the change is atomic. The mode of the clients file is `0644`. The file has public keys only.
- Run the script before `docker compose up -d`. Compose mounts the clients file with `create_host_path: false`. If the file does not exist, Docker refuses the mount and makes no directory. Docker Desktop on Windows can make a directory at the missing path and ignore this option. Identity then stops with the error "is a directory". Remove the directory and run the script.
- The script prints the next steps. They are the key owner, the two variables of the service in `.env` (`<SVC>_CLIENT_KEY_FILE` and `<SVC>_CLIENT_KEY_ID`), and a restart of identity.

Key owner and mode: the container user has the UID 65532. A Compose file secret keeps the owner and the mode of the host file. On Linux, run `sudo chown 65532:65532 secrets/<svc>-client-key.pem`. The script does not use `sudo`. On Docker Desktop, where you cannot change the owner, use `chmod 0444` on the key file. Keep the mode `0700` on the folder `secrets/`. That mode is then the only control. The script stops if the folder has a permission for group or other.

Rotation of a key:

1. Run `bash scripts/new-service-client.sh --rotate --kid <svc>-2 <svc>`. The script makes the key file `<svc>-client-key-<svc>-2.pem` and prints a `keys` entry. It does not change the clients file.
2. Add the printed entry to the `keys` of the client in the clients file. Restart identity.
3. Set the new key file and the new key ID in `.env`. Restart the service.
4. Delete the old key entry from the clients file. Restart identity.

Backup: keep a copy of the folder `secrets/`. It has the master key of identity, the client keys, and the clients file.

## Provisioning

`CONSTELLATION_SERVICES` has the service names, for example `identity,audit`. A name matches `^[a-z][a-z0-9_]{0,31}$`. The names `default`, `public`, `postgres`, `template0`, `template1`, and each name that starts with `pg_` are reserved. For each name `<svc>`, `.env` has `<SVC>_DB_PASSWORD` and `<SVC>_VALKEY_PASSWORD` (upper case).

Two one-shot services make the objects. They are idempotent. A second run gives the same result.

- `provision-postgres` makes the role `<svc>` and the database `<svc>` with the role as owner. It removes the `CONNECT` permission of `PUBLIC` and gives it to the role. A service cannot connect to the database of another service. The script also removes `CONNECT` and `TEMP` of `PUBLIC` on the databases `postgres` and `template1`, and it sets `CONNECTION LIMIT` of each role to `SERVICE_DB_CONNECTION_LIMIT`.
- `provision-valkey` makes the ACL user `<svc>`. The user can use the keys `<svc>:*` and the commands `+@all -@admin -@dangerous -@scripting -function -scan -randomkey -dbsize -memory`. Valkey does not filter `SCAN`, `RANDOMKEY`, `DBSIZE`, and `MEMORY` by key pattern, so they would show the key names of other services. A script (`EVAL`) can block Valkey for all services, so scripts are off. Each user also has two selectors for the event streams (see "Event stream ACL") and one selector for the audit streams (see "Audit stream ACL"). The reader user has two more. The script registers each service in the set `audit.apps` (see "Audit stream ACL"). The script saves the users to the ACL file in the `valkey-data` volume, so they stay after a restart. The ACL file has the SHA-256 hash of each password, not the password. When you delete a name from `CONSTELLATION_SERVICES`, `provision-valkey` deletes it from `audit.apps`. The ACL user of the name stays.

The scripts do not print passwords, and they do not put passwords on a command line. The scripts reject the placeholder `change-me`, a password with fewer than 12 characters, and a Valkey password with white space, before they change anything. Services connect to PostgreSQL directly. Do not put a pooler in transaction mode between them, because it breaks the advisory locks of the migrations.

## Add a service

1. Add the name to `CONSTELLATION_SERVICES` in `.env`.
2. Add `<SVC>_DB_PASSWORD` and `<SVC>_VALKEY_PASSWORD` to `.env`.
3. If the service gets tokens from identity, run `bash scripts/new-service-client.sh <svc> [role ...]` and follow the steps that it prints (see "Service clients").
4. Add a service block to `compose.yaml` (the template below). The `events` block is an example of a service client.
5. A new service gets 3 selectors: two for event streams and one for audit streams. A custom producer must use `constellation-platform-go` `v0.9.0` or later. An older producer logs a warning for each `SADD audit.streams`, because no user can write that set. `provision-valkey` registers the new service in `audit.apps`. The audit service does not find a service that is not registered, so run `provision-valkey` before the service starts. Only the user that `AUDIT_STREAM_READER` names reads audit streams. Do not name a new service as the reader.
6. Run the provisioning services: `docker compose run --rm provision-postgres` and `docker compose run --rm provision-valkey`. Then run `docker compose up -d`. Use `docker compose run --rm` because `docker compose up -d` does not start an exited one-shot container again when its configuration did not change.

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

Give the private key of the client as a Compose secret. Never put the key in `.env` or in an `environment` value, because `docker inspect` shows it. Add this to the service block and to the top level of `compose.yaml`. Keep the key file in the folder `secrets/` with the owner `65532:65532` and the mode `0400` (see "Service clients"):

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

Sizing rules for `VALKEY_MAXMEMORY`:

- Valkey holds the event streams, the audit streams, the login counters, the authorization codes, and the rate limit keys. When the memory is full, all writes of all services fail.
- Audit streams: plan for the audit entries of `AUDIT_STREAM_RETENTION` (see "Audit stream retention"). A denied token entry is approximately 1 KB. Identity `0.9.1` limits them. Denied token entries: approximately `(R / 24 + 1) x TOKEN_DENIED_GLOBAL limit x 1 KB`. `R` is the longer of `AUDIT_STREAM_RETENTION` and the longest stop of the audit service, in hours. With the default limit 100000 and `R` = 24, this is approximately 200 MB. Add approximately `(R / 24 + 1) x 14400 x 1 KB` (approximately 14 MB for `R` = 24) for each registered client, for the bucket `token_denied_client`. Add approximately 4800 denied login entries (approximately 5 MB) for each IP that you expect in 24 hours. Add approximately 2 MB of rate limit keys for each IPv6 /48 prefix. When the rate limits are off, the denied token bound is for each replica. Add a rate limit in the reverse proxy. When the memory is full, `provision-valkey` cannot register a new service.
- Use the longer of `AUDIT_STREAM_RETENTION` and the longest stop of the audit service. Do not make it shorter to save memory.
- Add the memory of the event streams and the other keys. Then add at least 25 percent of free memory. The AOF rewrite also needs memory.
- Watch `used_memory` and `maxmemory` in the metrics. Raise `VALKEY_MAXMEMORY` before `used_memory` is at 80 percent of it.

`valkey-server` does not run as root. A first start with an empty `valkey-data` volume writes the ACL file with the `default` user and the SHA-256 hash of `VALKEY_ADMIN_PASSWORD`. A later start does not change the file. `provision-valkey` always runs `ACL SAVE`, also with no service, so an old ACL file with a plain text password changes to a hash.

## Change an admin password

PostgreSQL, Valkey, and Grafana read the admin password at the first start of an empty volume only. A change of the value in `.env` alone has no effect. Use these steps, and then change the value in `.env`.

- PostgreSQL: `docker compose exec postgres psql -U postgres -c "ALTER ROLE postgres PASSWORD '<new>'"`.
- Valkey: `docker compose exec -e REDISCLI_AUTH=<old> valkey valkey-cli ACL SETUSER default '><new>'`. Then run `ACL SAVE` the same way. Then remove the old password with `ACL SETUSER default '<old'`, where `old` is the old password.
- Grafana: `docker compose exec grafana grafana cli admin reset-admin-password <new>`.

To change the password of a service, change the two values in `.env` and run both provisioning services again (see "Add a service", step 5). Then restart the service.

## Telemetry

Services send traces, metrics, and logs with OTLP to the collector. The collector sends metrics to Prometheus, logs to Loki, and traces to Tempo. Services push metrics. Prometheus does not scrape. Grafana has the three data sources, with links between logs and traces. No container sends usage data.

## Tests

Run the tests from the repository root. They need Docker.

```sh
bash scripts/check-compose.sh        # Static checks. No container runs.
bash tests/check-compose-cases.sh    # Negative cases of the static checks.
bash tests/new-service-client-cases.sh  # Tests of scripts/new-service-client.sh. Needs openssl, no Docker.
bash scripts/smoke-test.sh           # Live containers. Takes some minutes.
```

Check 5 of `scripts/check-compose.sh` requires the value `change-me` for each variable in `.env.example` that has `PASSWORD`, `SECRET`, `TOKEN`, or `KEY` in its name. Only the six exact names `IDENTITY_MASTER_KEY_FILE`, `IDENTITY_MASTER_KEY_ID`, `EVENTS_CLIENT_KEY_FILE`, `EVENTS_CLIENT_KEY_ID`, `AUDIT_CLIENT_KEY_FILE`, and `AUDIT_CLIENT_KEY_ID` can have any value. A name with the suffix `_FILE` or `_ID` is not exempt.

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

## Upgrade from v0.2.0 to v0.3.0

The release `v0.3.0` adds the events service and the event stream ACL. It moves the clients file of identity. Do these steps in this order:

1. Make a backup of the databases and of the folder `secrets/`.
2. Before you get the new files, copy the old clients file: `install -m 0644 config/identity/clients.yaml secrets/identity-clients.yaml`.
3. Get the files of the release `v0.3.0`.
4. In `.env`, add `events` to `CONSTELLATION_SERVICES`. Add `EVENTS_DB_PASSWORD`, `EVENTS_DB_PASSWORD_URLENCODED`, `EVENTS_VALKEY_PASSWORD`, `EVENTS_CLIENT_KEY_FILE`, and `EVENTS_CLIENT_KEY_ID`. Until these values exist, each Compose command stops with an error that names the variable.
5. Run `bash scripts/new-service-client.sh events`. Set the owner of the key as the script says.
6. Run `docker compose pull`, `docker compose run --rm provision-postgres`, `docker compose run --rm provision-valkey`, then `docker compose up -d`.
7. Examine the states with `docker compose ps`.

Identity `0.6.0` to `0.7.1`: client credentials tokens get the `app` claim. Read the release notes of identity `v0.7.0` and `v0.7.1` before the update.

## Upgrade from v0.3.0 to v0.4.0

The release `v0.4.0` adds the audit service and the audit stream ACL. Do these steps in this order:

1. Make a backup of the databases and of the folder `secrets/`.
2. Get the files of the release `v0.4.0`.
3. In `.env`, add `audit` to `CONSTELLATION_SERVICES`. Add `AUDIT_STREAM_READER=audit`, `AUDIT_DB_PASSWORD`, `AUDIT_DB_PASSWORD_URLENCODED`, `AUDIT_VALKEY_PASSWORD`, `AUDIT_CLIENT_KEY_FILE`, and `AUDIT_CLIENT_KEY_ID`. Until these values exist, each Compose command stops with an error that names the variable.
4. Run `bash scripts/new-service-client.sh audit`. Set the owner of the key as the script says.
5. Restart identity, because it reads the clients file only at the start: `docker compose restart identity`.
6. Run `docker compose pull`, `docker compose run --rm provision-postgres`, and `docker compose run --rm provision-valkey`, then `docker compose up -d`. Without the run of `provision-valkey`, the Valkey users keep the old ACL.
7. Examine the states with `docker compose ps`. The service `audit` shows `healthy`.

The audit service adds one more service role in PostgreSQL. Each service role can use up to `SERVICE_DB_CONNECTION_LIMIT` (default 50) connections. Keep the number of services times this value lower than `POSTGRES_MAX_CONNECTIONS`. Increase `POSTGRES_MAX_CONNECTIONS` before you add a service if the total is not lower.

## Upgrade from v0.4.x to v0.5.0

The release `v0.5.0` adds the trusted set `audit.apps`, identity `0.9.0`, and audit `0.2.0`. Do these steps in this order:

1. Make a backup of the databases and of the folder `secrets/`.
2. Get the files of the release `v0.5.0`.
3. Run `docker compose pull`.
4. Run `docker compose run --rm provision-valkey`. This registers each service in `audit.apps` and gives the transition selectors. It also removes the names that are not in `CONSTELLATION_SERVICES` from `audit.apps`. If the script exits with a nonzero code, stop the upgrade. The step 4 can fail on `SADD` when the Valkey memory is full. Fix the cause and run step 4 again before step 5.
5. Run `docker compose up -d`. This starts the audit image `0.2.0`.
6. As the admin user, run these checks. `<reader>` is the user that `AUDIT_STREAM_READER` names (default `audit`).
   - `SISMEMBER audit.apps <svc>` returns `1` for each name of `CONSTELLATION_SERVICES`.
   - `ACL DRYRUN <reader> SSCAN audit.apps 0` returns `OK`.
   - `ACL DRYRUN <reader> SREM audit.apps x` returns a text that has `no permissions`.
   - `ACL DRYRUN <svc> SADD audit.apps x` returns a text that has `no permissions` for each producer.

If step 5 comes before step 4, the audit service gets `NOPERM` on `SSCAN audit.apps` and counts `apps_error`. It finds no new producer. The table `known_apps` keeps the intake of the known apps. The fix is step 4.

The release `v0.6.0` deletes the transition selectors. See "Upgrade from v0.5.0 to v0.6.0".

Identity `0.9.0` limits the denied token entries. See "Audit stream retention" and "Valkey" for the buckets, the counter, and the new sizing rule.

## Upgrade from v0.7.0 to v0.8.0

The release `v0.8.0` changes the helpdesk image from `0.1.0` to `0.2.0`. The new version has an MCP server. It needs the new variable `HELPDESK_PUBLIC_BASE_URL`. Do these steps in this order:

1. Make a backup of the databases and of the folder `secrets/`.
2. Get the files of the release `v0.8.0`.
3. In `.env`, add `HELPDESK_PUBLIC_BASE_URL`. See "Helpdesk service" for the rule. Until the variable exists, each Compose command stops with an error that names the variable. Optional: `HELPDESK_MCP_ALLOWED_ORIGINS`.
4. Run `docker compose pull`.
5. Run `docker compose up -d`. This starts the helpdesk `0.2.0`.
6. Examine the states with `docker compose ps`. The service `helpdesk` shows `healthy`.

### Roll back to v0.7.0

1. Get the files of the release `v0.7.0`.
2. Run `docker compose up -d`. The helpdesk `0.1.0` ignores the new variables. The helpdesk `0.2.0` made no database change that `0.1.0` cannot read. Read the release notes of the helpdesk before you roll back.

## Upgrade from v0.6.0 to v0.7.0

The release `v0.7.0` adds the helpdesk service `0.1.0`. It also changes the default of `POSTGRES_MAX_CONNECTIONS` from `200` to `250`. The helpdesk is a fourth service role, and 4 times 50 is not lower than 200. Do these steps in this order:

1. Make a backup of the databases and of the folder `secrets/`.
2. Get the files of the release `v0.7.0`.
3. In `.env`, add `helpdesk` to `CONSTELLATION_SERVICES`. Add `HELPDESK_DB_PASSWORD`, `HELPDESK_DB_PASSWORD_URLENCODED`, `HELPDESK_VALKEY_PASSWORD`, `HELPDESK_CLIENT_KEY_FILE`, and `HELPDESK_CLIENT_KEY_ID`. Until these values exist, each Compose command stops with an error that names the variable. Optional: `HELPDESK_BIND`, `HELPDESK_PORT`, and `HELPDESK_TRUSTED_PROXIES`.
4. If `.env` sets `POSTGRES_MAX_CONNECTIONS`, set it to 250 or more. An install with no value gets the new default. Keep the number of services times `SERVICE_DB_CONNECTION_LIMIT` lower than this value.
5. Run `bash scripts/new-service-client.sh helpdesk events:producer`. Set the owner of the key as the script says. The script changes the clients file, so restart identity: `docker compose restart identity`. A change of the clients file needs a restart of identity.
6. Run `docker compose pull`.
7. Run `docker compose run --rm provision-postgres` and `docker compose run --rm provision-valkey`. This makes the database, the role, and the Valkey user of the helpdesk, and it registers `helpdesk` in `audit.apps`.
8. Run `docker compose up -d`. If you changed `POSTGRES_MAX_CONNECTIONS`, this restarts PostgreSQL.
9. Examine the states with `docker compose ps`. The service `helpdesk` shows `healthy`.

### Roll back to v0.6.0

1. Get the files of the release `v0.6.0`.
2. Remove the entry `helpdesk` from `secrets/identity-clients.yaml`. Delete the key file `secrets/helpdesk-client-key.pem`. Restart identity with `docker compose restart identity`. Identity reads the clients file only at the start. Until the restart, the helpdesk client can still get tokens.
3. As the admin user of Valkey, run `ACL DELUSER helpdesk` and `SREM audit.apps helpdesk`. Then run `ACL SAVE`. The Valkey user can otherwise still write to `audit.stream:helpdesk` and `events.stream:helpdesk`.
4. In `.env`, remove `helpdesk` from `CONSTELLATION_SERVICES`. Remove `HELPDESK_DB_PASSWORD`, `HELPDESK_DB_PASSWORD_URLENCODED`, `HELPDESK_VALKEY_PASSWORD`, `HELPDESK_CLIENT_KEY_FILE`, and `HELPDESK_CLIENT_KEY_ID`. Remove the other helpdesk variables.
5. Run `docker compose up -d --remove-orphans`.
6. Optional: to remove the data, drop the database `helpdesk` and the role `helpdesk` in PostgreSQL. Do a backup first. To keep the data and block access, run `ALTER ROLE helpdesk NOLOGIN`.

## Upgrade from v0.5.0 to v0.6.0

The release `v0.6.0` uses identity `0.9.1` and events `0.2.1`. Both images use `constellation-platform-go` `v0.9.0`. They write only the streams `audit.stream:<app>`. The release deletes the two transition selectors for the set `audit.streams` from each Valkey user. A custom producer must use `constellation-platform-go` `v0.9.0` or later before you upgrade. An older producer logs a warning for each `SADD audit.streams`. Do these steps in this order:

1. Make a backup of the databases and of the folder `secrets/`.
2. Get the files of the release `v0.6.0`.
3. Run `docker compose pull`.
4. Run `docker compose run --rm provision-valkey`. Each run replaces all selectors of each user. Identity `0.9.0` and events `0.2.0` still run until step 5. They log the warning `streams: cannot add the app to the audit index`. This warning is normal. No audit entry is lost.
5. Run `docker compose up -d`. This starts identity `0.9.1` and events `0.2.1`.
6. As the admin user, run these checks. `<reader>` is the user that `AUDIT_STREAM_READER` names (default `audit`).
   - `ACL DRYRUN <svc> SADD audit.streams x` returns a text that has `no permissions` for each service.
   - `ACL DRYRUN <reader> SSCAN audit.streams 0` returns a text that has `no permissions`.
   - Run `ACL USERS`. Do the `ACL DRYRUN <user> SADD audit.streams x` check for each user in the list, also for a user that you deleted from `CONSTELLATION_SERVICES` before the upgrade. The provision script does not delete an ACL user, thus such a user keeps its `v0.5.0` rule. Delete each old user that you do not use with `ACL DELUSER <user>`, then run `ACL SAVE`.
7. Optional: as the admin user, run `DEL audit.streams`. The set has no effect on the discovery, and no active service user can write it again. The delete has a lasting effect after this release.

Use the identity and events images of this release. Older producers log a warning for each `SADD audit.streams`.

### Roll back to v0.5.0

1. Get the files of the release `v0.5.0`.
2. Run `docker compose pull`.
3. Run `docker compose run --rm provision-valkey`. The script of `v0.5.0` gives the transition selectors again.
4. Run `docker compose up -d`.

A previous `DEL audit.streams` has no effect on the discovery, because the audit image `0.2.0` reads only `audit.apps`.
