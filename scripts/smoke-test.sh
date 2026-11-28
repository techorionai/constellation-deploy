#!/usr/bin/env bash
# Smoke test of the Compose project with live containers.
#
# Usage: bash scripts/smoke-test.sh
#
# The script uses the project name "constellation-smoke" and the env file tests/smoke.env.
# It runs on the host and in GitHub CI. Do not run it under "act": a relative bind mount does
# not work under "act" with a Docker Desktop host.
# All checks run inside the Compose network with "docker compose exec" or "docker compose run",
# not through host ports. At the end, also after a failed check, the script removes the
# containers and the volumes of the project.
set -u

# Stop Git Bash on Windows from changing paths in the arguments of docker.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

project=constellation-smoke
env_file=tests/smoke.env
extra_env_file=tests/.smoke-extra.env
key_dir=""
failures=()

dc() {
  docker compose -p "$project" --env-file "$env_file" "$@"
}

# Read a value from tests/smoke.env. The file is not a shell file, so the script does not source it.
envval() {
  grep -E "^$1=" "$env_file" | head -n 1 | cut -d= -f2-
}

# I16: remove the project, also after a failed check, and examine that nothing stays.
cleanup() {
  local code=$?
  dc down -v --remove-orphans >/dev/null 2>&1
  rm -f "$extra_env_file"
  if [ -n "$key_dir" ]; then
    rm -rf "$key_dir"
  fi
  local containers volumes
  if [ -n "$key_dir" ] && [ -e "$key_dir" ]; then
    echo "FAIL: I16: the temporary key folder stays after the cleanup"
    code=1
  elif [ -n "$key_dir" ]; then
    echo "ok: I16: the temporary key folder is removed"
  fi
  containers="$(docker ps -aq --filter "label=com.docker.compose.project=$project")"
  volumes="$(docker volume ls -q --filter "label=com.docker.compose.project=$project")"
  if [ -n "$containers$volumes" ]; then
    echo "FAIL: I16: containers or volumes of $project stay after docker compose down -v"
    code=1
  else
    echo "ok: I16: no container or volume of $project stays"
  fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Run a check. Print ok or FAIL with the name. Print the output of a failed check.
run_check() {
  local name="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    echo "ok: $name"
  else
    echo "FAIL: $name"
    printf '%s\n' "$output" | head -n 20
    failures+=("$name")
  fi
}

# Run a command many times until it succeeds or the time limit ends.
poll() {
  local limit="$1"
  shift
  local end=$((SECONDS + limit))
  while ! "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$end" ]; then
      return 1
    fi
    sleep 2
  done
}

# PostgreSQL. Arguments: user, password, database, then arguments for psql.
pg() {
  local user="$1" password="$2" database="$3"
  shift 3
  dc exec -T -e PGPASSWORD="$password" postgres \
    psql -h postgres -U "$user" -d "$database" -v ON_ERROR_STOP=1 -tA "$@"
}

# Valkey. Arguments: user, password, then the command.
vk() {
  local user="$1" password="$2"
  shift 2
  dc exec -T -e REDISCLI_AUTH="$password" valkey valkey-cli --user "$user" "$@"
}

# Valkey as the admin user.
vk_admin() {
  dc exec -T -e REDISCLI_AUTH="$(envval VALKEY_ADMIN_PASSWORD)" valkey valkey-cli "$@"
}

# curl in the grafana container. The container has curl and is in the Compose network.
gcurl() {
  dc exec -T grafana curl "$@"
}

expect_output() {
  # Arguments: expected text, then the command. The command can fail.
  local want="$1" output
  shift
  output="$("$@" 2>&1)"
  if ! printf '%s' "$output" | grep -qF -- "$want"; then
    echo "expected text: $want"
    echo "output: $output"
    return 1
  fi
}

# Arguments: expected output, then the command. The whole output must be equal to the text.
# A substring match is not enough: an error text can have the same letters.
expect_exact() {
  local want="$1" output
  shift
  output="$("$@" 2>&1 | tr -d '\r')" || true
  if [ "$output" != "$want" ]; then
    echo "expected output: $want"
    echo "output: $output"
    return 1
  fi
}

# ACL DRYRUN as the admin user. An allowed command gives exactly OK. A refused command gives a
# text that has "no permissions". The text is not an error reply. Arguments: user, then the command.
acl_allowed() {
  expect_exact OK vk_admin ACL DRYRUN "$@"
}
acl_refused() {
  expect_output "no permissions" vk_admin ACL DRYRUN "$@"
}

# No user except the admin user (named default) can run SREM on an audit key. ACL DRYRUN uses the rules of the
# user, with all selectors and all categories, so a category such as +@set or +@write also fails.
no_srem_selector() {
  local users user key
  users="$(vk_admin ACL USERS 2>&1 | tr -d '\r')"
  if [ -z "$users" ] || ! printf '%s\n' "$users" | grep -qx audit; then
    echo "the list of ACL users has no user audit: $users"
    return 1
  fi
  for user in $users; do
    [ "$user" = "default" ] && continue
    for key in audit.apps audit.streams; do
      acl_refused "$user" SREM "$key" x || { echo "user $user can run SREM on $key"; return 1; }
    done
  done
}

# I61: no user can use the old set audit.streams. ACL DRYRUN uses all selectors and categories.
test_no_audit_streams_access() {
  local users user
  users="$(vk_admin ACL USERS 2>&1 | tr -d '\r')"
  if [ -z "$users" ] || ! printf '%s\n' "$users" | grep -qx audit; then
    echo "the list of ACL users has no user audit: $users"
    return 1
  fi
  for user in $users; do
    [ "$user" = "default" ] && continue
    acl_refused "$user" SADD audit.streams x || { echo "user $user can run SADD on audit.streams"; return 1; }
    acl_refused "$user" SSCAN audit.streams 0 || { echo "user $user can run SSCAN on audit.streams"; return 1; }
    acl_refused "$user" SMEMBERS audit.streams || { echo "user $user can run SMEMBERS on audit.streams"; return 1; }
    acl_refused "$user" DEL audit.streams || { echo "user $user can run DEL on audit.streams"; return 1; }
  done
  if vk_admin ACL LIST 2>&1 | tr -d '\r' | grep -F 'audit.streams' | grep -v '^user default ' >/dev/null; then
    echo "a rule of ACL LIST has the text audit.streams"
    return 1
  fi
}

# SISMEMBER audit.apps as the admin user. Arguments: name, expected reply (0 or 1).
expect_registered() {
  expect_exact "$2" vk_admin SISMEMBER audit.apps "$1"
}

# The checks of the audit.apps ACL for the reader and one producer. Arguments: reader, producer.
check_audit_apps_acl() {
  acl_allowed "$1" SSCAN audit.apps 0 || return 1
  acl_refused "$1" SREM audit.apps x || return 1
  acl_refused "$1" SADD audit.apps x || return 1
  acl_refused "$2" SADD audit.apps x || return 1
  acl_refused "$2" SSCAN audit.apps 0 || return 1
  acl_refused "$2" SREM audit.apps x || return 1
  no_srem_selector
}

expect_refused() {
  # Arguments: expected text, then the command. The command must fail.
  local want="$1" output
  shift
  if output="$("$@" 2>&1)"; then
    echo "the command did not fail: $output"
    return 1
  fi
  if ! printf '%s' "$output" | grep -qF -- "$want"; then
    echo "expected text: $want"
    echo "output: $output"
    return 1
  fi
}

# I2 (and I18): connect to the own database, make a table, use advisory locks.
test_postgres_own() {
  local svc="$1" password="$2"
  pg "$svc" "$password" "$svc" \
    -c 'CREATE TABLE IF NOT EXISTS smoke_t (id int)' \
    -c 'SELECT pg_advisory_lock(42)' \
    -c 'SELECT pg_advisory_unlock(42)' >/dev/null
}

# I5: SET, GET, and XADD in the own key prefix.
test_valkey_own() {
  local svc="$1" password="$2"
  expect_exact OK vk "$svc" "$password" SET "$svc:k" v || return 1
  expect_exact v vk "$svc" "$password" GET "$svc:k" || return 1
  vk "$svc" "$password" XADD "$svc:s" '*' f v >/dev/null
}

http_ready() {
  gcurl -fsS -o /dev/null "$1"
}

# I1: start the project and wait for the states.
# The script does not use "up --wait". Compose 5 stops "up --wait" with an error when a
# one-shot service exits, also with exit code 0, if no other service depends on it.
# A service of a later idea depends on both provisioning services, and then "--wait" works.
test_up() {
  local end=$((SECONDS + 300))
  dc up -d || { dc ps -a; return 1; }
  until check_states >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$end" ]; then
      check_states
      dc ps -a
      dc logs --tail 40
      return 1
    fi
    sleep 3
  done
}

# Each long-running service with a health check is healthy. The collector, Loki, and Tempo
# are running. Both provisioning services exited with code 0.
check_states() {
  local states service state health code
  states="$(dc ps -a --format '{{.Service}} {{.State}} {{.Health}} {{.ExitCode}}')"
  for service in postgres valkey prometheus grafana identity events audit helpdesk; do
    health="$(printf '%s\n' "$states" | awk -v s="$service" '$1 == s { print $3 }')"
    if [ "$health" != "healthy" ]; then
      echo "$service is not healthy: $health"
      return 1
    fi
  done
  for service in otel-collector loki tempo; do
    state="$(printf '%s\n' "$states" | awk -v s="$service" '$1 == s { print $2 }')"
    if [ "$state" != "running" ]; then
      echo "$service is not running: $state"
      return 1
    fi
  done
  for service in provision-postgres provision-valkey; do
    state="$(printf '%s\n' "$states" | awk -v s="$service" '$1 == s { print $2 }')"
    code="$(printf '%s\n' "$states" | awk -v s="$service" '$1 == s { print $NF }')"
    if [ "$state" != "exited" ] || [ "$code" != "0" ]; then
      echo "$service did not exit with code 0: $state $code"
      return 1
    fi
  done
}

# I17: the ready endpoints of the services with no Compose health check.
test_ready_endpoints() {
  local url
  for url in http://otel-collector:13133/ http://loki:3100/ready http://tempo:3200/ready; do
    if ! poll 120 http_ready "$url"; then
      echo "not ready in 120 seconds: $url"
      return 1
    fi
  done
}

# I8: the Valkey settings.
test_valkey_settings() {
  expect_output yes vk_admin CONFIG GET appendonly || return 1
  expect_output noeviction vk_admin CONFIG GET maxmemory-policy
}

# I20: commands that Valkey does not filter by key pattern are refused.
test_valkey_unfiltered_commands() {
  local password
  password="$(envval SMOKE_A_VALKEY_PASSWORD)"
  expect_output NOPERM vk smoke_a "$password" SCAN 0 || return 1
  expect_output NOPERM vk smoke_a "$password" RANDOMKEY || return 1
  expect_output NOPERM vk smoke_a "$password" DBSIZE || return 1
  expect_output NOPERM vk smoke_a "$password" MEMORY STATS
}

# I9: run both provisioning services again.
test_reprovision() {
  dc run --rm --no-deps -T provision-postgres || return 1
  dc run --rm --no-deps -T provision-valkey || return 1
  test_postgres_own smoke_a "$(envval SMOKE_A_DB_PASSWORD)" || return 1
  test_valkey_own smoke_a "$(envval SMOKE_A_VALKEY_PASSWORD)"
}

# I10: restart Valkey. The ACL users stay.
test_valkey_restart() {
  dc restart valkey || return 1
  dc up -d --wait valkey || return 1
  test_valkey_own smoke_a "$(envval SMOKE_A_VALKEY_PASSWORD)"
}

# I19: valkey-server does not run as root.
test_valkey_not_root() {
  local uids uid
  uids="$(dc exec -T valkey grep '^Uid:' /proc/1/status)" || return 1
  for uid in $(printf '%s' "$uids" | cut -f2-); do
    if [ "$uid" = "0" ]; then
      echo "process 1 runs as root: $uids"
      return 1
    fi
  done
}

# I11: the flow for a new service.
test_new_service() {
  local pw_db="smoke-c-db-pw" pw_valkey="smoke-c-valkey-pw"
  sed -e "s|^CONSTELLATION_ENV_FILE=.*|CONSTELLATION_ENV_FILE=$extra_env_file|" \
    -e 's|^CONSTELLATION_SERVICES=.*|CONSTELLATION_SERVICES=smoke_a,smoke_b,identity,events,audit,smoke_c|' \
    "$env_file" > "$extra_env_file"
  {
    echo "SMOKE_C_DB_PASSWORD=$pw_db"
    echo "SMOKE_C_VALKEY_PASSWORD=$pw_valkey"
  } >> "$extra_env_file"
  local output
  output="$(docker compose -p "$project" --env-file "$extra_env_file" run --rm --no-deps -T provision-postgres 2>&1)" \
    || { printf '%s\n' "$output"; return 1; }
  output="$output
$(docker compose -p "$project" --env-file "$extra_env_file" run --rm --no-deps -T provision-valkey 2>&1)" \
    || { printf '%s\n' "$output"; return 1; }
  # R18: the output of the provisioning of smoke_c has no password of smoke_c.
  if printf '%s' "$output" | grep -qF -e "$pw_db" -e "$pw_valkey"; then
    echo "the output of the provisioning has a password of smoke_c"
    return 1
  fi
  test_postgres_own smoke_c "$pw_db" || return 1
  expect_registered smoke_c 1 || return 1
  test_valkey_own smoke_c "$pw_valkey"
}

random_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# Send one OTLP HTTP request from the postgres container. This container is on the network
# "services" only, like a business service. Arguments: signal path, JSON body.
otlp_post() {
  dc exec -T postgres wget -q -T 10 -O /dev/null --header 'Content-Type: application/json' \
    --post-data "$2" "http://otel-collector:4318/v1/$1"
}

# I12: one trace, one metric, and one log record go through the collector.
test_telemetry() {
  local now trace_id span_id marker resource
  now="$(date +%s)000000000"
  trace_id="$(random_hex 16)"
  span_id="$(random_hex 8)"
  marker="smoke-log-$(random_hex 4)"
  resource='"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"smoke-test"}}]}'

  otlp_post traces "{\"resourceSpans\":[{$resource,\"scopeSpans\":[{\"scope\":{\"name\":\"smoke\"},\"spans\":[{\"traceId\":\"$trace_id\",\"spanId\":\"$span_id\",\"name\":\"smoke-span\",\"kind\":1,\"startTimeUnixNano\":\"$now\",\"endTimeUnixNano\":\"$now\"}]}]}]}" || return 1
  otlp_post metrics "{\"resourceMetrics\":[{$resource,\"scopeMetrics\":[{\"scope\":{\"name\":\"smoke\"},\"metrics\":[{\"name\":\"smoke_test_gauge\",\"gauge\":{\"dataPoints\":[{\"timeUnixNano\":\"$now\",\"asDouble\":1}]}}]}]}]}" || return 1
  otlp_post logs "{\"resourceLogs\":[{$resource,\"scopeLogs\":[{\"scope\":{\"name\":\"smoke\"},\"logRecords\":[{\"timeUnixNano\":\"$now\",\"severityText\":\"INFO\",\"body\":{\"stringValue\":\"$marker\"},\"traceId\":\"$trace_id\",\"spanId\":\"$span_id\"}]}]}]}" || return 1

  poll 60 gcurl -fsS -o /dev/null "http://tempo:3200/api/traces/$trace_id" \
    || { echo "Tempo has no trace $trace_id in 60 seconds"; return 1; }
  poll 60 prometheus_has_metric \
    || { echo "Prometheus has no metric smoke_test_gauge in 60 seconds"; return 1; }
  poll 60 loki_has_log "$marker" \
    || { echo "Loki has no log line $marker in 60 seconds"; return 1; }
}

prometheus_has_metric() {
  gcurl -fsS -G --data-urlencode 'query=smoke_test_gauge{job="smoke-test"}' \
    http://prometheus:9090/api/v1/query | grep -q '"smoke_test_gauge"'
}

loki_has_log() {
  gcurl -fsS -G --data-urlencode 'query={service_name="smoke-test"}' \
    http://loki:3100/loki/api/v1/query_range | grep -qF -- "$1"
}

# I22: a container on the network "services" cannot reach the stores. It reaches the collector.
test_network_isolation() {
  local url output
  for url in http://loki:3100/ready http://tempo:3200/ready http://prometheus:9090/-/ready; do
    if output="$(dc exec -T postgres wget -q -T 5 -O /dev/null "$url" 2>&1)"; then
      echo "a container on the network services reaches $url"
      return 1
    fi
    if ! printf '%s' "$output" | grep -qF 'bad address'; then
      echo "expected a name error for $url, got: $output"
      return 1
    fi
  done
  otlp_post logs '{"resourceLogs":[]}' || { echo "the collector does not accept an OTLP request"; return 1; }
}

# I23: the scripts reject the placeholder, a short password, and white space in a Valkey password.
# The command line of "docker compose run" has test values. They are not real passwords.
test_weak_passwords() {
  local weak msg
  for weak in change-me short-pw; do
    msg=placeholder
    [ "$weak" = short-pw ] && msg="too short"
    expect_refused "$msg" dc run --rm --no-deps -T -e "SMOKE_A_DB_PASSWORD=$weak" provision-postgres || return 1
    expect_refused "$msg" dc run --rm --no-deps -T -e "POSTGRES_PASSWORD=$weak" provision-postgres || return 1
    expect_refused "$msg" dc run --rm --no-deps -T -e "SMOKE_A_VALKEY_PASSWORD=$weak" provision-valkey || return 1
    expect_refused "$msg" dc run --rm --no-deps -T -e "VALKEY_ADMIN_PASSWORD=$weak" provision-valkey || return 1
    expect_refused "$msg" dc run --rm --no-deps -T -e "POSTGRES_PASSWORD=$weak" postgres || return 1
    expect_refused "$msg" dc run --rm --no-deps -T -e "VALKEY_ADMIN_PASSWORD=$weak" valkey || return 1
    expect_refused "$msg" dc run --rm --no-deps -T -e "GF_SECURITY_ADMIN_PASSWORD=$weak" grafana || return 1
    expect_refused "$msg" dc run --rm --no-deps -T -e "GF_SECURITY_SECRET_KEY=$weak" grafana || return 1
  done
  expect_refused "white space" dc run --rm --no-deps -T \
    -e "SMOKE_A_VALKEY_PASSWORD=has a space inside" provision-valkey || return 1
  # The refused runs changed nothing: the passwords of smoke_a still work.
  test_postgres_own smoke_a "$(envval SMOKE_A_DB_PASSWORD)" || return 1
  test_valkey_own smoke_a "$(envval SMOKE_A_VALKEY_PASSWORD)"
}

# I13: Grafana health and data sources.
test_grafana() {
  local user password sources
  user="$(envval GRAFANA_ADMIN_USER)"
  password="$(envval GRAFANA_ADMIN_PASSWORD)"
  gcurl -fsS http://localhost:3000/api/health | grep -Eq '"database":[[:space:]]*"ok"' \
    || { echo "Grafana health is not ok"; return 1; }
  sources="$(gcurl -fsS -u "$user:$password" http://localhost:3000/api/datasources)" || return 1
  local name
  for name in prometheus loki tempo; do
    if ! printf '%s' "$sources" | grep -Eq "\"uid\":[[:space:]]*\"$name\""; then
      echo "Grafana has no data source $name"
      return 1
    fi
  done
}

# I14: no anonymous access.
test_grafana_anonymous() {
  local code
  code="$(gcurl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/datasources)" || return 1
  if [ "$code" != "401" ]; then
    echo "expected HTTP 401, got $code"
    return 1
  fi
}

# I15: the logs of the provisioning services have no password.
test_no_password_in_logs() {
  local logs line password
  logs="$(dc logs provision-postgres provision-valkey 2>&1)" || return 1
  while IFS= read -r line; do
    password="${line#*=}"
    if printf '%s' "$logs" | grep -qF -- "$password"; then
      echo "a log has the value of ${line%%=*}"
      return 1
    fi
  done < <(grep -E '^[A-Za-z0-9_]*_PASSWORD=' "$env_file")
}

# Make the keys in a temporary folder with the procedures of docs/compose.md: the master key of
# identity, and the client keys and the clients file of the events and audit services (scripts/new-service-client.sh).
# The folder has mode 0700 and each key file has mode 0444, so the container user can read it.
# The script exports the paths. A shell variable overrides the env file.
make_keys() {
  key_dir="$(mktemp -d)" || return 1
  chmod 0700 "$key_dir"
  openssl rand -base64 32 > "$key_dir/identity-master-key" || return 1
  chmod 0444 "$key_dir/identity-master-key"
  bash scripts/new-service-client.sh --secrets-dir "$key_dir" --clients-file "$key_dir/identity-clients.yaml" \
    events >/dev/null || return 1
  bash scripts/new-service-client.sh --secrets-dir "$key_dir" --clients-file "$key_dir/identity-clients.yaml" \
    audit >/dev/null || return 1
  bash scripts/new-service-client.sh --secrets-dir "$key_dir" --clients-file "$key_dir/identity-clients.yaml" \
    helpdesk events:producer >/dev/null || return 1
  # The smoke client calls the helpdesk and reads the event catalog. Only the host reads its key.
  bash scripts/new-service-client.sh --secrets-dir "$key_dir" --clients-file "$key_dir/identity-clients.yaml" \
    smoke_helpdesk helpdesk:support_agent events:reader >/dev/null || return 1
  chmod 0444 "$key_dir/helpdesk-client-key.pem"
  chmod 0444 "$key_dir/audit-client-key.pem"
  chmod 0444 "$key_dir/events-client-key.pem"
  # Docker on Windows needs a Windows path. Git Bash gives one with cygpath.
  local host_dir="$key_dir"
  if command -v cygpath >/dev/null 2>&1; then
    host_dir="$(cygpath -m "$key_dir")"
  fi
  IDENTITY_MASTER_KEY_FILE="$host_dir/identity-master-key"
  EVENTS_CLIENT_KEY_FILE="$host_dir/events-client-key.pem"
  AUDIT_CLIENT_KEY_FILE="$host_dir/audit-client-key.pem"
  HELPDESK_CLIENT_KEY_FILE="$host_dir/helpdesk-client-key.pem"
  IDENTITY_CLIENTS_PATH="$host_dir/identity-clients.yaml"
  export IDENTITY_MASTER_KEY_FILE EVENTS_CLIENT_KEY_FILE AUDIT_CLIENT_KEY_FILE HELPDESK_CLIENT_KEY_FILE IDENTITY_CLIENTS_PATH
}

# Read a URL from the container postgres. It is in the network "services", like a business service.
svc_get() {
  dc exec -T postgres wget -q -T 10 -O - "$1"
}

# I30 (identity) and I48 (events): the URL-encoded database password decodes to the database
# password. The password has characters that need encoding, so a wrong encoded value stops the
# service from connecting. The argument is the prefix of the variable names.
check_password_encoding() {
  local prefix="$1" plain encoded decoded
  plain="$(envval "${prefix}_DB_PASSWORD")"
  encoded="$(envval "${prefix}_DB_PASSWORD_URLENCODED")"
  if [ "$plain" = "$encoded" ]; then
    echo "the test password does not need encoding"
    return 1
  fi
  decoded="$(printf '%b' "${encoded//%/\\x}")"
  if [ "$decoded" != "$plain" ]; then
    echo "the encoded password does not decode to ${prefix}_DB_PASSWORD"
    return 1
  fi
}

test_identity_password_encoding() {
  check_password_encoding IDENTITY
}

test_events_password_encoding() {
  check_password_encoding EVENTS
}

# I25: the JWKS has one public ES256 key and no private part.
test_identity_jwks() {
  local jwks count
  jwks="$(svc_get http://identity:8080/.well-known/jwks.json)" || return 1
  count="$(printf '%s' "$jwks" | grep -o '"kty"' | wc -l | tr -d ' ')"
  if [ "$count" != "1" ]; then
    echo "expected one key, got $count: $jwks"
    return 1
  fi
  local want
  for want in '"kty"[[:space:]]*:[[:space:]]*"EC"' '"crv"[[:space:]]*:[[:space:]]*"P-256"' '"alg"[[:space:]]*:[[:space:]]*"ES256"'; do
    if ! printf '%s' "$jwks" | grep -Eq "$want"; then
      echo "the JWKS does not match $want: $jwks"
      return 1
    fi
  done
  if printf '%s' "$jwks" | grep -Eq '"d"[[:space:]]*:'; then
    echo "the JWKS has a private key part"
    return 1
  fi
}

# I26: the discovery document has the issuer.
test_identity_discovery() {
  local doc issuer
  issuer="$(envval IDENTITY_ISSUER)"
  doc="$(svc_get http://identity:8080/.well-known/openid-configuration)" || return 1
  if ! printf '%s' "$doc" | grep -Eq "\"issuer\"[[:space:]]*:[[:space:]]*\"$issuer\""; then
    echo "the issuer is not $issuer: $doc"
    return 1
  fi
}

# I27: the log has one record about the setup link. It has no link and no token.
test_identity_setup_log() {
  local logs count
  logs="$(dc logs identity 2>&1 | tr -d '\r')" || return 1
  count="$(printf '%s\n' "$logs" | grep -cF 'identity: first-admin setup link')"
  if [ "$count" != "1" ]; then
    echo "expected one setup link record, got $count"
    return 1
  fi
  if printf '%s' "$logs" | grep -qF '/setup?token='; then
    echo "the log has a setup link"
    return 1
  fi
}

# I29: the log has no password and no master key.
test_identity_no_secret_in_logs() {
  local logs value name
  logs="$(dc logs identity 2>&1)" || return 1
  # I35 stores a test client secret. It must not be in the log, and not in the stderr of I35.
  if printf '%s' "$logs" | grep -qF -- "$idp_test_secret"; then
    echo "the log has the test client secret"
    return 1
  fi
  if [ -f "$key_dir/idp-stderr" ] && grep -qF -- "$idp_test_secret" "$key_dir/idp-stderr"; then
    echo "the stderr of set-idp-secret has the test client secret"
    return 1
  fi
  for name in IDENTITY_DB_PASSWORD IDENTITY_VALKEY_PASSWORD; do
    value="$(envval "$name")"
    if printf '%s' "$logs" | grep -qF -- "$value"; then
      echo "the log has the value of $name"
      return 1
    fi
  done
  value="$(tr -d '\r\n' < "$key_dir/identity-master-key")"
  if printf '%s' "$logs" | grep -qF -- "$value"; then
    echo "the log has the master key"
    return 1
  fi
}

# I31: the rate limit of GET /setup. The bucket setup_invite gives 10 requests in 15 minutes for one
# IP. Request 11 must get 429 and a Retry-After header. The requests have a bad token and no
# Sec-Fetch-* header, so the cross-site check of identity does not give 403. This is the only
# check that calls /setup.
test_identity_setup_rate_limit() {
  local i out code
  for i in 1 2 3 4 5 6 7 8 9 10 11; do
    # BusyBox wget does not print all headers of an error response. Thus the request is raw HTTP
    # through nc in the postgres container, which is in the network "services". The sleep keeps
    # the connection open. Without it, nc closes the connection and identity cancels the request.
    out="$(dc exec -T postgres sh -c \
      "(printf 'GET /setup?token=smoke-bad-token HTTP/1.0\r\nHost: identity:8080\r\n\r\n'; sleep 1) | nc -w 5 identity 8080" \
      2>&1 | tr -d '\r')" || true
    code="$(printf '%s\n' "$out" | sed -n 's/^ *HTTP\/[0-9.]* \([0-9]*\).*/\1/p' | head -n 1)"
    if [ "$i" -le 10 ] && [ "$code" = "429" ]; then
      echo "request $i got 429 before the limit"
      return 1
    fi
  done
  if [ "$code" != "429" ]; then
    echo "request 11 got status $code, expected 429"
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -iEq '^retry-after: *[0-9]+'; then
    echo "request 11 has no Retry-After header: $out"
    return 1
  fi
}

# Test value for the client secret of check I35. It is for tests only. I29 looks for it in the log.
idp_test_secret="smoke-idp-secret-0123456789"

# A raw HTTP GET to identity from the container postgres, which is in the network "services".
# The output has the status line, the headers, and the body. BusyBox wget does not print the
# headers of an error response, so the request goes through nc (see I31).
identity_raw_get() {
  dc exec -T postgres sh -c \
    "(printf 'GET $1 HTTP/1.0\r\nHost: identity:8080\r\n\r\n'; sleep 1) | nc -w 5 identity 8080" \
    2>&1 | tr -d '\r'
}

# The HTTP status code of a response of identity_raw_get.
http_code() {
  printf '%s\n' "$1" | sed -n 's/^ *HTTP\/[0-9.]* \([0-9]*\).*/\1/p' | head -n 1
}

# I32: the login page gives 200 and has no link to an upstream login (no provider is set).
test_identity_login_no_provider() {
  local out
  out="$(identity_raw_get /login)"
  if [ "$(http_code "$out")" != "200" ]; then
    echo "GET /login did not give 200: $(printf '%s\n' "$out" | head -n 1)"
    return 1
  fi
  if printf '%s' "$out" | grep -qF '/login/oidc/'; then
    echo "the login page has a link to /login/oidc/ with no provider set"
    return 1
  fi
}

# I33: the login page has the CSP script-src 'self'. Passkeys are on, because the issuer host is localhost.
test_identity_login_csp() {
  local out
  out="$(identity_raw_get /login)"
  if ! printf '%s\n' "$out" | grep -iE '^content-security-policy:' | grep -qF "script-src 'self'"; then
    echo "the login page has no CSP with script-src 'self'"
    printf '%s\n' "$out" | head -n 20
    return 1
  fi
}

# I34: the command unlock-login for an email that is not locked.
test_identity_unlock_login() {
  # The command logs to stderr. The result is on stdout.
  local out code
  out="$(dc exec -T identity /identity unlock-login nobody@example.com 2>/dev/null)"
  code=$?
  out="$(printf '%s' "$out" | tr -d '\r')"
  if [ "$code" != "0" ] || [ "$out" != "not locked" ]; then
    echo "unlock-login: exit $code, stdout: $out"
    return 1
  fi
}

# I35: set-idp-secret reads stdin. A value gives exit 0 and "stored". Empty stdin gives exit 2.
# The stderr of the command goes to a file in the key folder. I29 looks for the test secret in it.
test_identity_set_idp_secret() {
  local out code
  out="$(printf '%s\n' "$idp_test_secret" | dc exec -T identity /identity set-idp-secret google 2>"$key_dir/idp-stderr")"
  code=$?
  out="$(printf '%s' "$out" | tr -d '\r')"
  if [ "$code" != "0" ] || [ "$out" != "stored" ]; then
    echo "set-idp-secret with a value: exit $code, output: $out"
    return 1
  fi
  out="$(printf '' | dc exec -T identity /identity set-idp-secret google 2>/dev/null)"
  code=$?
  if [ "$code" != "2" ]; then
    echo "set-idp-secret with empty stdin: expected exit 2, got $code. Output: $out"
    return 1
  fi
}

# Wait until identity is healthy.
identity_healthy() {
  [ "$(dc ps --format '{{.Service}} {{.Health}}' | awk '$1 == "identity" { print $2 }')" = "healthy" ]
}

# I36: a test Google client ID in a second env file. The login page then has a link to Google and
# no link to Microsoft. The secret of I35 is stored, so identity starts. Discovery is lazy, so no
# real account is necessary. After the check, the stack uses the first env file again.
# This check runs after I35 and after all other identity checks.
test_identity_google_enabled() {
  local result=0 out
  sed -e "s|^CONSTELLATION_ENV_FILE=.*|CONSTELLATION_ENV_FILE=$extra_env_file|" "$env_file" > "$extra_env_file"
  echo "IDENTITY_GOOGLE_CLIENT_ID=smoke-test-client.apps.googleusercontent.com" >> "$extra_env_file"
  if docker compose -p "$project" --env-file "$extra_env_file" up -d --no-deps --force-recreate identity >/dev/null 2>&1 \
    && poll 120 identity_healthy; then
    out="$(identity_raw_get /login)"
    if ! printf '%s' "$out" | grep -qF '/login/oidc/google'; then
      echo "the login page has no link to /login/oidc/google"
      result=1
    fi
    if printf '%s' "$out" | grep -qF '/login/oidc/microsoft'; then
      echo "the login page has a link to /login/oidc/microsoft"
      result=1
    fi
    out="$(identity_raw_get /login/oidc/microsoft)"
    if [ "$(http_code "$out")" != "404" ]; then
      echo "GET /login/oidc/microsoft did not give 404: $(printf '%s\n' "$out" | head -n 1)"
      result=1
    fi
    # The log of the identity container that started with the provider on has no test secret.
    if dc logs identity 2>&1 | grep -qF -- "$idp_test_secret"; then
      echo "the log of identity with a Google client ID has the test client secret"
      result=1
    fi
  else
    echo "identity did not become healthy with a Google client ID"
    dc logs --tail 20 identity
    result=1
  fi
  rm -f "$extra_env_file"
  if ! { dc up -d --no-deps --force-recreate identity >/dev/null 2>&1 && poll 120 identity_healthy; }; then
    echo "identity did not become healthy after the restore of the first env file"
    result=1
  fi
  return "$result"
}

# Wait until the events service is healthy.
events_healthy() {
  [ "$(dc ps --format '{{.Service}} {{.Health}}' | awk '$1 == "events" { print $2 }')" = "healthy" ]
}

# I37: the events service is healthy (it starts after identity accepted its client key).
test_events_healthy() {
  events_healthy || { echo "events is not healthy"; dc logs --tail 20 events; return 1; }
}

# I38: the readiness endpoint of the events service, from the network "services". The service is
# ready only after identity accepted its client assertion and its manifest.
test_events_ready() {
  svc_get http://events:9090/readyz >/dev/null
}

# The number of log records of identity about a refused client authentication.
identity_refusals() {
  dc logs identity 2>&1 | grep -F 'token request failed' | grep -cF 'invalid_client'
}

# I39: a wrong key ID in a second env file. The events service must not become ready, identity must
# refuse the key ID (a new "token request failed" record with invalid_client), and its log
# has no private key. After the check, the stack uses the first env file again.
test_events_wrong_key_id() {
  local result=0 i key_body before after
  before="$(identity_refusals)"
  sed -e "s|^CONSTELLATION_ENV_FILE=.*|CONSTELLATION_ENV_FILE=$extra_env_file|" \
    -e 's|^EVENTS_CLIENT_KEY_ID=.*|EVENTS_CLIENT_KEY_ID=events-wrong|' "$env_file" > "$extra_env_file"
  docker compose -p "$project" --env-file "$extra_env_file" up -d --no-deps --force-recreate events >/dev/null 2>&1 \
    || { echo "could not recreate events"; result=1; }
  for ((i = 0; i < 12; i++)); do
    sleep 5
    if events_healthy; then
      echo "events became healthy with a wrong key ID"
      result=1
      break
    fi
  done
  after="$(identity_refusals)"
  if [ "$after" -le "$before" ]; then
    echo "identity did not log a refused token request for the wrong key ID ($before before, $after after)"
    result=1
  fi
  key_body="$(sed -n 2p "$key_dir/events-client-key.pem")"
  if dc logs events 2>&1 | grep -qF -e 'PRIVATE KEY' -e "$key_body"; then
    echo "the events log has private key text"
    result=1
  fi
  rm -f "$extra_env_file"
  if ! { dc up -d --no-deps --force-recreate events >/dev/null 2>&1 && poll 120 events_healthy; }; then
    echo "events did not become healthy after the restore of the first env file"
    dc logs --tail 20 events
    result=1
  fi
  return "$result"
}

# Succeed if the text on stdin has an entry ID (the text <ms>-<seq> on one line).
has_entry_id() {
  tr -d '\r' | grep -qE '^[0-9]+-[0-9]+$'
}

# I40 (and I43): a service writes its own stream and not the stream of another app.
test_stream_write_own() {
  local pw out
  pw="$(envval SMOKE_A_VALKEY_PASSWORD)"
  out="$(vk smoke_a "$pw" XADD events.stream:smoke_a '*' k v 2>&1)"
  if ! printf '%s\n' "$out" | has_entry_id; then
    echo "XADD to the own stream gave: $out"
    return 1
  fi
  expect_output NOPERM vk smoke_a "$pw" XADD events.stream:smoke_b '*' k v
}

# I41 (and I44): a service reads, acks, and cleans up on the stream of another app. It cannot trim
# or delete that stream. The argument is the name of the consumer group.
test_stream_consume() {
  local group="$1" pw out id
  pw="$(envval SMOKE_A_VALKEY_PASSWORD)"
  vk_admin XADD events.stream:smoke_b '*' k v >/dev/null || return 1
  expect_exact OK vk smoke_a "$pw" XGROUP CREATE events.stream:smoke_b "$group" 0 || return 1
  out="$(vk smoke_a "$pw" XREADGROUP GROUP "$group" c1 COUNT 1 STREAMS events.stream:smoke_b '>' 2>&1 | tr -d '\r')"
  id="$(printf '%s\n' "$out" | grep -E '^[0-9]+-[0-9]+$' | head -n 1)"
  if [ -z "$id" ]; then
    echo "XREADGROUP gave no entry: $out"
    return 1
  fi
  expect_exact 1 vk smoke_a "$pw" XACK events.stream:smoke_b "$group" "$id" || return 1
  expect_output c1 vk smoke_a "$pw" XINFO CONSUMERS events.stream:smoke_b "$group" || return 1
  expect_exact 0 vk smoke_a "$pw" XGROUP DELCONSUMER events.stream:smoke_b "$group" c1 || return 1
  expect_output NOPERM vk smoke_a "$pw" XTRIM events.stream:smoke_b MINID 0 || return 1
  expect_output NOPERM vk smoke_a "$pw" DEL events.stream:smoke_b
}

# I42: the user events has the same selectors as each other service user (decision D1).
test_stream_events_user() {
  local pw out
  pw="$(envval EVENTS_VALKEY_PASSWORD)"
  expect_output NOPERM vk events "$pw" XADD events.stream:smoke_a '*' k v || return 1
  expect_output NOPERM vk events "$pw" DEL events.stream:smoke_a || return 1
  # The check makes its own entry and its own group. It does not use the group of I41.
  vk_admin XADD events.stream:smoke_b '*' k v >/dev/null || return 1
  expect_exact OK vk events "$pw" XGROUP CREATE events.stream:smoke_b smoke_events_check 0 || return 1
  expect_output smoke_events_check vk events "$pw" XINFO GROUPS events.stream:smoke_b || return 1
  out="$(vk events "$pw" XADD events.stream:events '*' k v 2>&1)"
  if ! printf '%s\n' "$out" | has_entry_id; then
    echo "XADD to the stream events gave: $out"
    return 1
  fi
  # The audit producer selectors: the user events writes its own audit stream and not the audit
  # stream of another app. It cannot read audit streams or list the set.
  out="$(vk events "$pw" XADD audit.stream:events '*' k v 2>&1)"
  if ! printf '%s\n' "$out" | has_entry_id; then
    echo "XADD to the own audit stream gave: $out"
    return 1
  fi
  expect_output NOPERM vk events "$pw" XADD audit.stream:smoke_a '*' k v || return 1
  expect_output NOPERM vk events "$pw" XRANGE audit.stream:events - + || return 1
  expect_output NOPERM vk events "$pw" SSCAN audit.streams 0 || return 1
  # The reader user audit has the event selectors and the reader selectors.
  pw="$(envval AUDIT_VALKEY_PASSWORD)"
  expect_exact OK vk audit "$pw" XGROUP CREATE events.stream:smoke_b smoke_audit_events_check 0 || return 1
  expect_output smoke_audit_events_check vk audit "$pw" XINFO GROUPS events.stream:smoke_b || return 1
  # No selector gives access to the old set audit.streams.
  expect_output NOPERM vk audit "$pw" SSCAN audit.streams 0 || return 1
  expect_output smoke_a vk audit "$pw" SSCAN audit.apps 0 || return 1
  expect_output NOPERM vk audit "$pw" SREM audit.apps x || return 1
  expect_output NOPERM vk audit "$pw" SREM audit.streams x || return 1
  # The producer events cannot write or list the trusted set.
  pw="$(envval EVENTS_VALKEY_PASSWORD)"
  expect_output NOPERM vk events "$pw" SADD audit.apps x || return 1
  expect_output NOPERM vk events "$pw" SSCAN audit.apps 0 || return 1
  pw="$(envval AUDIT_VALKEY_PASSWORD)"
  expect_output NOPERM vk audit "$pw" XADD audit.stream:smoke_a '*' k v || return 1
  expect_output NOPERM vk audit "$pw" XADD events.stream:smoke_b '*' k v
}

# I43: the selectors stay after a Valkey restart.
test_stream_after_restart() {
  test_valkey_restart || return 1
  test_stream_write_own
}

# I44: the selectors stay after a new provisioning run. Each user has exactly 3 selectors, and the
# reader user audit has 5. The run registers the first list in audit.apps and deletes smoke_c.
test_stream_after_reprovision() {
  local count output name
  output="$(dc run --rm --no-deps -T provision-valkey 2>&1)" || { printf '%s\n' "$output"; return 1; }
  if ! printf '%s\n' "$output" | grep -qx "valkey: unregistered smoke_c"; then
    echo "no 'valkey: unregistered smoke_c' in the output: $output"
    return 1
  fi
  test_stream_consume smoke_a.again || return 1
  for name in smoke_a smoke_b identity events audit; do
    expect_registered "$name" 1 || return 1
  done
  expect_registered smoke_c 0 || return 1
  check_audit_apps_acl audit smoke_a || return 1
  count="$(vk_admin ACL LIST 2>&1 | tr -d '\r' | grep '^user smoke_a ' | grep -o '(~' | wc -l | tr -d ' ')"
  if [ "$count" != "3" ]; then
    echo "the user smoke_a has $count selectors, not 3"
    return 1
  fi
  count="$(selector_count audit)"
  if [ "$count" != "5" ]; then
    echo "the user audit has $count selectors, not 5"
    return 1
  fi
}

# I60: two bad members in audit.apps, "Bad-name" and "*". The script does not delete them, does not
# print them, and exits 0. The member "*" must not expand to file names in the shell of the script.
test_audit_apps_bad_member() {
  local output name warnings
  vk_admin SADD audit.apps Bad-name '*' >/dev/null || return 1
  output="$(dc run --rm --no-deps -T provision-valkey 2>&1)" || { printf '%s\n' "$output"; vk_admin SREM audit.apps Bad-name '*' >/dev/null; return 1; }
  if [ "$(vk_admin SISMEMBER audit.apps Bad-name | tr -d '\r')" != "1" ]; then
    echo "Bad-name was deleted"
    vk_admin SREM audit.apps '*' >/dev/null
    return 1
  fi
  if [ "$(vk_admin SISMEMBER audit.apps '*' | tr -d '\r')" != "1" ]; then
    echo "the member * was deleted"
    vk_admin SREM audit.apps Bad-name >/dev/null
    return 1
  fi
  vk_admin SREM audit.apps Bad-name '*' >/dev/null || return 1
  warnings="$(printf '%s\n' "$output" | grep -cF "WARNING: valkey: audit.apps has a bad name, not deleted" || true)"
  if [ "$warnings" != "2" ]; then
    echo "expected 2 warnings, got $warnings: $output"
    return 1
  fi
  if printf '%s\n' "$output" | grep -qF -e "Bad-name" -e "unregistered"; then
    echo "the output has a bad name or an unregistered line: $output"
    return 1
  fi
  for name in smoke_a smoke_b identity events audit; do
    expect_registered "$name" 1 || return 1
  done
}

# I45: the database role and the Valkey user of the events service are isolated.
test_events_isolation() {
  local pw
  pw="$(envval EVENTS_VALKEY_PASSWORD)"
  expect_refused CONNECT pg events "$(envval EVENTS_DB_PASSWORD)" identity -c 'SELECT 1' || return 1
  expect_output NOPERM vk events "$pw" GET identity:k || return 1
  expect_exact OK vk events "$pw" SET events:smoke 1
}

# I46: the log of the events service has no password, no private key, and no token.
test_events_no_secret_in_logs() {
  local logs key_body name
  logs="$(dc logs events 2>&1)" || return 1
  key_body="$(sed -n 2p "$key_dir/events-client-key.pem")"
  for name in EVENTS_DB_PASSWORD EVENTS_VALKEY_PASSWORD; do
    if printf '%s' "$logs" | grep -qF -- "$(envval "$name")"; then
      echo "the events log has the value of $name"
      return 1
    fi
  done
  if printf '%s' "$logs" | grep -qF -e 'PRIVATE KEY' -e "$key_body" -e 'eyJ'; then
    echo "the events log has a private key or a token"
    return 1
  fi
}

# Wait until the audit service is healthy.
audit_healthy() {
  [ "$(dc ps --format '{{.Service}} {{.Health}}' | awk '$1 == "audit" { print $2 }')" = "healthy" ]
}

# I49: the audit service is healthy and its readiness endpoint gives 200. It is ready only after
# identity accepted its client assertion and its manifest, so the readiness check also proves that
# identity has the manifest of audit. A direct check of the manifest in identity needs a token with
# the right permission and is not practical in this test (decision mode Auto, base rule).
test_audit_healthy() {
  audit_healthy || { echo "audit is not healthy"; dc logs --tail 20 audit; return 1; }
  svc_get http://audit:9090/readyz >/dev/null
}

# I50: a service writes its own audit stream. It cannot write the audit stream of another app
# and cannot write the old set audit.streams.
test_audit_producer() {
  local pw out
  pw="$(envval SMOKE_A_VALKEY_PASSWORD)"
  out="$(vk smoke_a "$pw" XADD audit.stream:smoke_a '*' k v 2>&1)"
  if ! printf '%s\n' "$out" | has_entry_id; then
    echo "XADD to the own audit stream gave: $out"
    return 1
  fi
  expect_output NOPERM vk smoke_a "$pw" XADD audit.stream:smoke_b '*' k v || return 1
  # The producer cannot write the trusted set audit.apps. provision-valkey registers the name.
  expect_output NOPERM vk smoke_a "$pw" SADD audit.apps smoke_a || return 1
  # No selector gives access to the old set audit.streams.
  expect_output NOPERM vk smoke_a "$pw" SADD audit.streams smoke_a || return 1
}

# I51: a service that is not the reader cannot read audit streams or list the set.
test_audit_no_reader() {
  local pw
  pw="$(envval SMOKE_A_VALKEY_PASSWORD)"
  expect_output NOPERM vk smoke_a "$pw" XREADGROUP GROUP smoke_g c1 COUNT 1 STREAMS audit.stream:smoke_a '>' || return 1
  expect_output NOPERM vk smoke_a "$pw" XRANGE audit.stream:smoke_a - + || return 1
  expect_output NOPERM vk smoke_a "$pw" SSCAN audit.streams 0 || return 1
  expect_output NOPERM vk smoke_a "$pw" SSCAN audit.apps 0
}

# I52: the reader user reads audit streams and lists the set. It cannot write an audit stream.
test_audit_reader() {
  local pw
  pw="$(envval AUDIT_VALKEY_PASSWORD)"
  expect_exact OK vk audit "$pw" XGROUP CREATE audit.stream:smoke_a smoke_reader_check 0 || return 1
  expect_output smoke_reader_check vk audit "$pw" XINFO GROUPS audit.stream:smoke_a || return 1
  expect_output smoke_a vk audit "$pw" SSCAN audit.apps 0 || return 1
  expect_output NOPERM vk audit "$pw" SSCAN audit.streams 0 || return 1
  # XREADGROUP needs +xreadgroup in the reader selector.
  expect_output audit.stream:smoke_a vk audit "$pw" XREADGROUP GROUP smoke_reader_check c1 COUNT 1 STREAMS audit.stream:smoke_a '>' || return 1
  expect_output NOPERM vk audit "$pw" XADD audit.stream:smoke_a '*' k v
}

# A lowercase UUID in the text form.
new_uuid() {
  local h
  h="$(openssl rand -hex 16)"
  printf '%s-%s-4%s-a%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

# I53: end to end. A service writes an audit entry in its stream. The audit service reads it and
# stores it. The table rejected_entries has no row.
test_audit_end_to_end() {
  local pw id now event rows rejected apass end out
  pw="$(envval SMOKE_A_VALKEY_PASSWORD)"
  apass="$(envval AUDIT_DB_PASSWORD)"
  id="$(new_uuid)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  event="{\"specversion\":\"1.0\",\"id\":\"$id\",\"source\":\"/smoke_a\",\"type\":\"smoke_a.audit.recorded\",\"time\":\"$now\",\"datacontenttype\":\"application/json\",\"actor\":\"smoke_a\",\"actortype\":\"service\",\"data\":{\"action\":\"smoke_a:item:update\",\"result\":\"success\"}}"
  out="$(vk smoke_a "$pw" XADD audit.stream:smoke_a '*' event "$event" 2>&1)"
  if ! printf '%s\n' "$out" | has_entry_id; then
    echo "XADD gave: $out"
    return 1
  fi
  end=$((SECONDS + 90))
  while :; do
    rows="$(pg audit "$apass" audit -c "SELECT count(*) FROM audit_entries WHERE service = 'smoke_a' AND entry_id = '$id'" | tr -d '\r')"
    [ "$rows" = "1" ] && break
    if [ "$SECONDS" -ge "$end" ]; then
      echo "no row in audit_entries in 90 seconds for $id"
      dc logs --tail 20 audit
      return 1
    fi
    sleep 3
  done
  rejected="$(pg audit "$apass" audit -c "SELECT count(*) FROM rejected_entries" | tr -d '\r')"
  if [ "$rejected" != "0" ]; then
    echo "rejected_entries has $rejected rows"
    return 1
  fi
}

# Count the selectors of a Valkey user.
selector_count() {
  vk_admin ACL LIST 2>&1 | tr -d '\r' | grep "^user $1 " | grep -o '(~' | wc -l | tr -d ' '
}

# The names of the Valkey users that have the selector (~audit.apps +sscan).
reader_selector_users() {
  vk_admin ACL LIST 2>&1 | tr -d '\r' | grep -E '\(~audit\.apps [^)]*\+sscan\)' | awk '{ print $2 }'
}

# I54: AUDIT_STREAM_READER=events in a second env file. After a provisioning run, the user events
# has the reader selectors and the user audit has not. After the check, the first env file
# is used again.
test_audit_reader_variable() {
  local result=0
  sed -e "s|^CONSTELLATION_ENV_FILE=.*|CONSTELLATION_ENV_FILE=$extra_env_file|" \
    -e 's|^AUDIT_STREAM_READER=.*|AUDIT_STREAM_READER=events|' "$env_file" > "$extra_env_file"
  docker compose -p "$project" --env-file "$extra_env_file" run --rm --no-deps -T provision-valkey >/dev/null 2>&1 \
    || { echo "provision-valkey failed with the second env file"; result=1; }
  if [ "$(selector_count events)" != "5" ] || [ "$(selector_count audit)" != "3" ]; then
    echo "events has $(selector_count events) selectors and audit has $(selector_count audit), not 5 and 3"
    result=1
  fi
  if ! reader_selector_users | grep -qx events || reader_selector_users | grep -qx audit; then
    echo "the selector (~audit.apps +sscan) is not only on the user events"
    result=1
  fi
  check_audit_apps_acl events audit || result=1
  rm -f "$extra_env_file"
  dc run --rm --no-deps -T provision-valkey >/dev/null 2>&1 || { echo "provision-valkey failed after the restore"; result=1; }
  if [ "$(selector_count audit)" != "5" ] || [ "$(selector_count events)" != "3" ]; then
    echo "the restore did not give 5 selectors to audit and 3 to events"
    result=1
  fi
  if ! reader_selector_users | grep -qx audit || reader_selector_users | grep -qx events; then
    echo "the selector (~audit.apps +sscan) is not only on the user audit after the restore"
    result=1
  fi
  check_audit_apps_acl audit events || result=1
  return "$result"
}

# The CloudEvent id of one denied token entry of I58. I59 reads it. The checks run in subshells,
# so the id goes through a file in the key folder.
denied_id_file() {
  printf '%s/denied-event-id' "$key_dir"
}

# The shell text that sends one raw POST /oauth/token to identity. Argument: client ID.
# The container postgres runs the text. The body goes in as an argument of printf.
identity_token_script() {
  local body
  body="grant_type=client_credentials&client_id=$1&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=a.b.c"
  printf '%s' "(printf 'POST /oauth/token HTTP/1.0\r\nHost: identity:8080\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ${#body}\r\n\r\n%s' '$body'; sleep 1) | nc -w 5 identity 8080"
}

# One raw POST /oauth/token to identity from the container postgres. Argument: client ID.
# The output has the status line, the headers, and the body.
identity_raw_token() {
  dc exec -T postgres sh -c "$(identity_token_script "$1")" 2>&1 | tr -d '\r'
}

# N raw POST /oauth/token requests at the same time, from one shell in the container postgres.
# They all arrive in a few seconds, so they are in one window of a rate limit bucket.
# The output has one status line for each request. Arguments: client ID, N.
identity_token_burst() {
  dc exec -T postgres sh -c \
    "i=0; while [ \$i -lt $2 ]; do ( $(identity_token_script "$1") | head -n 1 ) & i=\$((i + 1)); done; wait" \
    2>&1 | tr -d '\r'
}

# The entries of audit.stream:identity after an ID, as admin. The ID is exclusive.
identity_entries_after() {
  vk_admin XRANGE audit.stream:identity "($1" + 2>&1 | tr -d '\r'
}

# The denied token entries of unknown clients in the output of identity_entries_after.
count_unknown_client_denied() {
  grep -E '"grant": *"client_credentials"' | grep -E '"reason": *"invalid_client"' | grep -vcF '"clientId"' || true
}

# I58: identity 0.9.0 limits the denied token entries. 40 requests in a short burst with one unknown client ID
# come from one IP (the container postgres), so the bucket token_denied (30 in 1 minute) applies.
# Identity writes no clientId for an unknown client, so the check filters by grant and reason.
test_identity_denied_limit() {
  local last cid out code count end
  last="$(vk_admin XREVRANGE audit.stream:identity + - COUNT 1 2>&1 | tr -d '\r' | head -n 1)"
  case "$last" in
    [0-9]*-[0-9]*) ;;
    *) last="0-0" ;;
  esac
  cid="smoke-unknown-$(openssl rand -hex 8)"
  # One full request, then a burst of 39 requests. The 40 requests are in one 1 minute window.
  out="$(identity_raw_token "$cid")"
  code="$(http_code "$out")"
  if [ "$code" != "401" ] || ! printf '%s\n' "$out" | grep -qF 'invalid_client'; then
    echo "request 1 got status $code: $(printf "%s" "$out" | tail -n 3)"
    return 1
  fi
  out="$(identity_token_burst "$cid" 39)"
  count="$(printf '%s\n' "$out" | grep -cE '^HTTP/[0-9.]+ 401' || true)"
  if [ "$count" != "39" ]; then
    echo "$count of 39 burst requests got status 401: $(printf '%s\n' "$out" | sort | uniq -c | head -n 5)"
    return 1
  fi
  end=$((SECONDS + 30))
  while :; do
    count="$(identity_entries_after "$last" | count_unknown_client_denied)"
    [ "$count" -ge 30 ] && break
    if [ "$SECONDS" -ge "$end" ]; then
      echo "only $count denied entries in 30 seconds, expected 30"
      echo "last id: $last, entries after: $(identity_entries_after "$last" | grep -c '^[0-9]*-[0-9]*$')"
      identity_entries_after "$last" | head -n 3 | cut -c1-400
      dc logs --tail 5 identity
      return 1
    fi
    sleep 2
  done
  sleep 5
  count="$(identity_entries_after "$last" | count_unknown_client_denied)"
  if [ "$count" != "30" ]; then
    echo "$count denied entries after the wait, expected 30"
    return 1
  fi
  identity_entries_after "$last" | grep -E '"grant": *"client_credentials"' | grep -E '"reason": *"invalid_client"' | grep -vF '"clientId"' | head -n 1 \
    | grep -oE '"id": *"[0-9a-f-]{36}"' | head -n 1 | cut -d'"' -f4 > "$(denied_id_file)"
  if [ ! -s "$(denied_id_file)" ]; then
    echo "no CloudEvent id in the denied entries"
    return 1
  fi
}

# I59: the denied entry of I58 is in audit_entries with service identity. The audit service finds
# identity through audit.apps, so this also shows the registration.
test_identity_entry_in_audit() {
  local id apass rows end
  id="$(cat "$(denied_id_file)" 2>/dev/null)"
  [ -n "$id" ] || { echo "no entry id from I58"; return 1; }
  apass="$(envval AUDIT_DB_PASSWORD)"
  end=$((SECONDS + 90))
  while :; do
    rows="$(pg audit "$apass" audit -c "SELECT count(*) FROM audit_entries WHERE service = 'identity' AND entry_id = '$id'" | tr -d '\r')"
    [ "$rows" = "1" ] && break
    if [ "$SECONDS" -ge "$end" ]; then
      echo "no row in audit_entries in 90 seconds for $id"
      dc logs --tail 20 audit
      return 1
    fi
    sleep 3
  done
}

# I55: the database role and the Valkey user of the audit service are isolated.
test_audit_isolation() {
  local pw
  pw="$(envval AUDIT_VALKEY_PASSWORD)"
  expect_refused CONNECT pg audit "$(envval AUDIT_DB_PASSWORD)" events -c 'SELECT 1' || return 1
  expect_output NOPERM vk audit "$pw" GET events:k || return 1
  expect_exact OK vk audit "$pw" SET audit:smoke 1
}

# I56: the log of the audit service has no password, no private key, and no token. The service
# connects with a database password that has the characters + / =.
test_audit_no_secret_in_logs() {
  local logs key_body name
  check_password_encoding AUDIT || return 1
  logs="$(dc logs audit 2>&1)" || return 1
  key_body="$(sed -n 2p "$key_dir/audit-client-key.pem")"
  for name in AUDIT_DB_PASSWORD AUDIT_VALKEY_PASSWORD; do
    if printf '%s' "$logs" | grep -qF -- "$(envval "$name")"; then
      echo "the audit log has the value of $name"
      return 1
    fi
  done
  if printf '%s' "$logs" | grep -qF -e 'PRIVATE KEY' -e "$key_body" -e 'eyJ'; then
    echo "the audit log has a private key or a token"
    return 1
  fi
}

# I57: the API of the audit service refuses a request with no token.
test_audit_no_token() {
  local code
  code="$(dc exec -T postgres wget -q -T 10 -S -O /dev/null http://audit:8080/v1/audit-entries 2>&1 | grep -oE 'HTTP/[0-9.]+ [0-9]+' | tail -n 1 | cut -d' ' -f2)"
  if [ "$code" != "401" ]; then
    echo "expected 401, got: $code"
    return 1
  fi
}

# True if the Docker host is Docker Desktop. It ignores create_host_path: false for a bind mount.
docker_desktop_host() {
  [ "$(docker info --format '{{.OperatingSystem}}' 2>/dev/null | tr -d '\r')" = "Docker Desktop" ]
}

# I47: identity does not start when the clients file is missing, and Docker makes no directory.
# On a Linux host, Docker refuses the mount and names the host path, and the check needs this.
# Docker Desktop makes the path and ignores create_host_path: false. There, identity must still
# stop with an error that names the file of the container and says that it is a directory.
test_identity_missing_clients_file() {
  local missing out container_path=/etc/identity/clients.yaml
  missing="${IDENTITY_CLIENTS_PATH%/*}/missing/identity-clients.yaml"
  if out="$(IDENTITY_CLIENTS_PATH="$missing" dc run --rm --no-deps -T identity 2>&1)"; then
    echo "identity started with a missing clients file"
    return 1
  fi
  if printf '%s' "$out" | grep -qF -- "$missing"; then
    # Docker refused the mount. It must not make the path.
    if [ -e "$key_dir/missing" ]; then
      echo "Docker made the path of the missing clients file"
      return 1
    fi
  elif docker_desktop_host; then
    if ! { printf '%s' "$out" | grep -qF -- "$container_path" && printf '%s' "$out" | grep -qF 'is a directory'; }; then
      echo "identity did not stop with an error that names $container_path as a directory"
      printf '%s\n' "$out"
      return 1
    fi
    echo "note: Docker Desktop made the path as a directory. Identity stopped with an error."
  else
    echo "the output does not name the path $missing"
    printf '%s\n' "$out"
    return 1
  fi
}

# Encode the text on stdin as base64url with no padding.
b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# Convert an ES256 signature from the DER form of openssl to the raw form r || s (64 bytes).
# The signature is on stdin as binary data. The output is binary data.
der_to_raw() {
  local hex rlen slen r s pos
  hex="$(od -An -tx1 -v | tr -d ' \n')"
  [ "${hex:0:2}" = "30" ] && [ "${hex:4:2}" = "02" ] || return 1
  rlen=$((16#${hex:6:2}))
  r="${hex:8:$((rlen * 2))}"
  pos=$((8 + rlen * 2))
  [ "${hex:$pos:2}" = "02" ] || return 1
  slen=$((16#${hex:$((pos + 2)):2}))
  s="${hex:$((pos + 4)):$((slen * 2))}"
  # An integer in DER can have a leading zero byte, or can be shorter than 32 bytes.
  while [ "${#r}" -gt 64 ]; do r="${r:2}"; done
  while [ "${#s}" -gt 64 ]; do s="${s:2}"; done
  r="$(printf '%064s' "$r" | tr ' ' 0)"
  s="$(printf '%064s' "$s" | tr ' ' 0)"
  # shellcheck disable=SC2059
  printf "$(printf '%s%s' "$r" "$s" | sed 's/../\\x&/g')"
}

# One HTTP/1.0 request from the container postgres to a service in the network "services".
# The output has the status line, the headers, and the body, with no CR characters.
# Arguments: host, port, method, path, bearer token (can be empty), content type, body.
net_http() {
  local host="$1" port="$2" method="$3" path="$4" token="$5" ctype="$6" body="${7:-}" auth=""
  if [ -n "$token" ]; then
    auth="Authorization: Bearer $token"$'\r\n'
  fi
  printf '%s %s HTTP/1.0\r\nHost: %s:%s\r\n%sContent-Type: %s\r\nContent-Length: %s\r\n\r\n%s' \
    "$method" "$path" "$host" "$port" "$auth" "$ctype" "${#body}" "$body" |
    dc exec -T postgres sh -c "(cat; sleep 2) | nc -w 5 $host $port" 2>&1 | tr -d '\r'
}

# The status code of the output of net_http (on stdin).
http_status_of() {
  sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p'
}

# The body of the output of net_http (on stdin).
http_body_of() {
  sed '1,/^$/d'
}

# The first string value of a JSON key in the text on stdin. Argument: key.
json_string() {
  grep -o "\"$1\" *: *\"[^\"]*\"" | head -n 1 | sed 's/^[^:]*: *"//;s/"$//'
}

# Get an access token with a client credentials grant and a private_key_jwt assertion.
# Arguments: client name, audience, scopes (separated by spaces). The key of the client is
# $key_dir/<client>-client-key.pem and the key ID is <client>-1. The assertion has the audience
# IDENTITY_ISSUER. Each call has a new jti. The output is the access token. If the status is not
# 200, the output is the status and the error code, and the return code is 1.
client_token() {
  local client="$1" audience="$2" scopes="$3" keyfile kid header claims input sig now jti form out status
  kid="$client-1"
  now="$(date +%s)"
  jti="$(openssl rand -hex 16)"
  header="$(printf '{"alg":"ES256","typ":"JWT","kid":"%s"}' "$kid" | b64url)"
  claims="$(printf '{"iss":"%s","sub":"%s","aud":"%s","jti":"%s","iat":%s,"exp":%s}' \
    "$client" "$client" "$(envval IDENTITY_ISSUER)" "$jti" "$now" "$((now + 240))" | b64url)"
  input="$header.$claims"
  # The openssl of Git Bash on Windows is a native build. It needs a Windows path.
  keyfile="$key_dir/$client-client-key.pem"
  if command -v cygpath >/dev/null 2>&1; then
    keyfile="$(cygpath -m "$keyfile")"
  fi
  sig="$(printf '%s' "$input" | openssl dgst -sha256 -sign "$keyfile" | der_to_raw | b64url)" || return 1
  form="grant_type=client_credentials&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer"
  form="$form&client_assertion=$input.$sig&audience=$audience&scope=${scopes// /%20}"
  form="${form//:/%3A}"
  out="$(net_http identity 8080 POST /oauth/token "" application/x-www-form-urlencoded "$form")"
  status="$(printf '%s\n' "$out" | http_status_of)"
  if [ "$status" != "200" ]; then
    echo "token request status $status, error $(printf '%s\n' "$out" | http_body_of | json_string error)"
    return 1
  fi
  printf '%s\n' "$out" | http_body_of | json_string access_token
}

helpdesk_healthy() {
  [ "$(dc ps --format '{{.Service}} {{.Health}}' | awk '$1 == "helpdesk" { print $2 }')" = "healthy" ]
}

helpdesk_ready() {
  svc_get http://helpdesk:9090/readyz >/dev/null
}

# S1: the helpdesk is healthy and its readiness endpoint gives 200. It is ready only after it
# published its event types and its manifest to the events service.
test_helpdesk_healthy() {
  if ! poll 120 helpdesk_healthy; then
    echo "helpdesk is not healthy in 120 seconds"
    dc logs --tail 30 helpdesk
    return 1
  fi
  poll 120 helpdesk_ready || { echo "helpdesk /readyz is not 200"; dc logs --tail 30 helpdesk; return 1; }
}

# S2: the Valkey user helpdesk writes its own event stream and audit stream. It cannot write the
# audit stream of another app. The name is a member of audit.apps.
test_helpdesk_acl() {
  acl_allowed helpdesk XADD events.stream:helpdesk '*' k v || return 1
  acl_allowed helpdesk XADD audit.stream:helpdesk '*' k v || return 1
  acl_refused helpdesk XADD audit.stream:events '*' k v || return 1
  expect_registered helpdesk 1
}

# The number of rows of audit_entries. Argument: the WHERE condition.
audit_count() {
  pg audit "$(envval AUDIT_DB_PASSWORD)" audit -c "SELECT count(*) FROM audit_entries WHERE $1" | tr -d '\r'
}

# Wait until a condition on audit_entries has one row or more. Arguments: the limit in seconds, the condition.
wait_audit_rows() {
  local end=$((SECONDS + $1)) rows
  while :; do
    rows="$(audit_count "$2")"
    [ -n "$rows" ] && [ "$rows" != "0" ] && return 0
    if [ "$SECONDS" -ge "$end" ]; then
      echo "no row in audit_entries in $1 seconds for: $2"
      return 1
    fi
    sleep 3
  done
}

# S3 and S4: a scoped service token creates a customer and a ticket. The audit database has the entry.
test_helpdesk_create() {
  local token out status customer ticket
  token="$(client_token smoke_helpdesk helpdesk "helpdesk:customer:write helpdesk:ticket:write")" ||
    { echo "$token"; return 1; }
  out="$(net_http helpdesk 8080 POST /v1/customers "$token" application/json \
    "{\"name\":\"Smoke Customer\",\"email\":\"smoke-$(openssl rand -hex 6)@example.test\"}")"
  status="$(printf '%s\n' "$out" | http_status_of)"
  customer="$(printf '%s\n' "$out" | http_body_of | json_string id)"
  if [ "$status" != "201" ] || [ -z "$customer" ]; then
    echo "POST /v1/customers gave: $out"
    return 1
  fi
  out="$(net_http helpdesk 8080 POST /v1/tickets "$token" application/json \
    "{\"subject\":\"Smoke ticket\",\"customerId\":\"$customer\"}")"
  status="$(printf '%s\n' "$out" | http_status_of)"
  ticket="$(printf '%s\n' "$out" | http_body_of | json_string id)"
  if [ "$status" != "201" ] || [ -z "$ticket" ]; then
    echo "POST /v1/tickets gave: $out"
    return 1
  fi
  wait_audit_rows 90 "service = 'helpdesk' AND action = 'helpdesk:ticket:create' AND result = 'success' AND actor = 'smoke_helpdesk' AND target_id = '$ticket'" ||
    { dc logs --tail 20 helpdesk; return 1; }
}

# S5: the event catalog of the events service has the 5 types of the helpdesk.
test_helpdesk_event_types() {
  local token out type
  token="$(client_token smoke_helpdesk events "events:catalog:read")" || { echo "$token"; return 1; }
  out="$(net_http events 8080 GET "/v1/event-types?app=helpdesk&pageSize=10" "$token" application/json)"
  for type in helpdesk.customer.created helpdesk.customer.updated helpdesk.ticket.created \
    helpdesk.ticket.updated helpdesk.ticket.status_changed; do
    if ! printf '%s' "$out" | grep -qF "\"$type\""; then
      echo "the event catalog has no type $type: $out"
      return 1
    fi
  done
}

# S6: a token with the scope helpdesk:ticket:read only cannot create a ticket. The refusal is in
# the audit database with the result denied.
test_helpdesk_denied() {
  local token out status
  token="$(client_token smoke_helpdesk helpdesk "helpdesk:ticket:read")" || { echo "$token"; return 1; }
  out="$(net_http helpdesk 8080 POST /v1/tickets "$token" application/json \
    '{"subject":"Denied ticket","customerId":"00000000-0000-4000-8000-000000000000"}')"
  status="$(printf '%s\n' "$out" | http_status_of)"
  if [ "$status" != "403" ]; then
    echo "POST /v1/tickets with a read scope gave: $out"
    return 1
  fi
  wait_audit_rows 90 "service = 'helpdesk' AND action = 'helpdesk:ticket:create' AND result = 'denied' AND actor = 'smoke_helpdesk'"
}

# S7: the log of the helpdesk has no password, no private key, and no token.
test_helpdesk_no_secret_in_logs() {
  local logs key_body name
  check_password_encoding HELPDESK || return 1
  logs="$(dc logs helpdesk 2>&1)" || return 1
  key_body="$(sed -n 2p "$key_dir/helpdesk-client-key.pem")"
  for name in HELPDESK_DB_PASSWORD HELPDESK_DB_PASSWORD_URLENCODED HELPDESK_VALKEY_PASSWORD; do
    if printf '%s' "$logs" | grep -qF -- "$(envval "$name")"; then
      echo "the helpdesk log has the value of $name"
      return 1
    fi
  done
  if printf '%s' "$logs" | grep -qF -e 'PRIVATE KEY' -e "$key_body" -e 'eyJ'; then
    echo "the helpdesk log has a private key or a token"
    return 1
  fi
}

# S8: the published port of the helpdesk is on 127.0.0.1 (the default of HELPDESK_BIND).
# The smoke file sets HELPDESK_PORT=0, so Docker picks a free host port.
test_helpdesk_port() {
  local mapping
  mapping="$(dc port helpdesk 8080 | tr -d '\r' | head -n 1)"
  case "$mapping" in
    127.0.0.1:*) ;;
    *) echo "the port mapping is: $mapping"; return 1 ;;
  esac
}

# S9: a scope that the client does not have gives invalid_scope.
test_helpdesk_invalid_scope() {
  local out
  if out="$(client_token smoke_helpdesk helpdesk "helpdesk:admin")"; then
    echo "a token was issued for a scope that the client does not have: $out"
    return 1
  fi
  case "$out" in
    "token request status 400, error invalid_scope") ;;
    *) echo "unexpected result: $out"; return 1 ;;
  esac
}

# A stateless request has the protocol version and the client capabilities in params._meta.
mcp_meta='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'

# A raw MCP request to the helpdesk from the container postgres, which is in the network "services".
# The output has the status line, the headers, and the body. BusyBox wget does not print the headers
# of an error response, so the request goes through nc. The server is stateless, so the request needs
# no handshake. The headers Mcp-Method and Mcp-Name must agree with the body.
# Arguments: the token (can be empty), the method, the name (the tool name or the resource URI, can be
# empty), the params without the braces (the _meta field is added).
mcp_raw() {
  local token="$1" method="$2" name="$3" params="$4" auth="" namehdr="" body
  if [ -n "$token" ]; then
    auth="Authorization: Bearer $token"$'\r\n'
  fi
  if [ -n "$name" ]; then
    namehdr="Mcp-Name: $name"$'\r\n'
  fi
  body="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":{$mcp_meta${params:+,$params}}}"
  printf 'POST /mcp HTTP/1.0\r\nHost: helpdesk:8080\r\n%sContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nMCP-Protocol-Version: 2026-07-28\r\nMcp-Method: %s\r\n%sContent-Length: %s\r\n\r\n%s' \
    "$auth" "$method" "$namehdr" "${#body}" "$body" |
    dc exec -T postgres sh -c "(cat; sleep 2) | nc -w 5 helpdesk 8080" 2>&1 | tr -d '\r'
}

# A tools/call request. Arguments: the token, the tool name, the arguments as JSON.
mcp_call() {
  mcp_raw "$1" tools/call "$2" "\"name\":\"$2\",\"arguments\":$3"
}

# Succeed if the output of mcp_call is HTTP 200 with a tool result that is not an error.
mcp_ok() {
  [ "$(printf '%s\n' "$1" | http_status_of)" = "200" ] &&
    ! printf '%s' "$1" | grep -q '"isError" *: *true'
}

# The ticket ID of M1 is in a file for M2 and M3, because run_check runs a check in a subshell.
# The file is "$key_dir/mcp-ticket-id".

# M1: an MCP client creates a customer and a ticket with a scoped token.
test_mcp_create() {
  local token out customer
  token="$(client_token smoke_helpdesk helpdesk "helpdesk:customer:write helpdesk:ticket:write helpdesk:ticket:read")" ||
    { echo "$token"; return 1; }
  out="$(mcp_call "$token" create_customer '{"name":"Smoke MCP Customer","email":"smoke-mcp@example.com"}')"
  mcp_ok "$out" || { echo "create_customer gave: $out"; return 1; }
  customer="$(printf '%s\n' "$out" | http_body_of | json_string id)"
  [ -n "$customer" ] || { echo "create_customer gave no customer ID: $out"; return 1; }
  out="$(mcp_call "$token" create_ticket "{\"subject\":\"Smoke MCP ticket\",\"customerId\":\"$customer\"}")"
  mcp_ok "$out" || { echo "create_ticket gave: $out"; return 1; }
  mcp_ticket_id="$(printf '%s\n' "$out" | http_body_of | json_string id)"
  printf '%s\n' "$mcp_ticket_id" >"$key_dir/mcp-ticket-id"
  [ -n "$mcp_ticket_id" ] || { echo "create_ticket gave no ticket ID: $out"; return 1; }
}

# M2: the audit database has the entry of the MCP ticket with the channel mcp.
test_mcp_audit() {
  mcp_ticket_id="$(cat "$key_dir/mcp-ticket-id" 2>/dev/null)"
  [ -n "$mcp_ticket_id" ] || { echo "M1 made no ticket"; return 1; }
  wait_audit_rows 90 "service = 'helpdesk' AND action = 'helpdesk:ticket:create' AND result = 'success' AND actor = 'smoke_helpdesk' AND target_id = '$mcp_ticket_id' AND details->>'channel' = 'mcp'" ||
    { dc logs --tail 20 helpdesk; return 1; }
}

mcp_event_in_stream() {
  vk_admin XRANGE events.stream:helpdesk - + 2>&1 | tr -d '\r' | grep -qF "tickets/$mcp_ticket_id"
}

# M3: the event stream of the helpdesk has the event of the MCP ticket.
test_mcp_event() {
  mcp_ticket_id="$(cat "$key_dir/mcp-ticket-id" 2>/dev/null)"
  [ -n "$mcp_ticket_id" ] || { echo "M1 made no ticket"; return 1; }
  if ! poll 90 mcp_event_in_stream; then
    echo "no event with the subject tickets/$mcp_ticket_id in events.stream:helpdesk"
    return 1
  fi
  vk_admin XRANGE events.stream:helpdesk - + | grep -qF "helpdesk.ticket.created" ||
    { echo "no event of the type helpdesk.ticket.created"; return 1; }
}

# M4: the event catalog has the type helpdesk.ticket.created with a data schema.
test_mcp_catalog() {
  local token out
  token="$(client_token smoke_helpdesk events "events:catalog:read")" || { echo "$token"; return 1; }
  out="$(net_http events 8080 GET "/v1/event-types?app=helpdesk&pageSize=10" "$token" application/json)"
  printf '%s' "$out" | grep -qF '"helpdesk.ticket.created"' || { echo "the catalog has no helpdesk.ticket.created: $out"; return 1; }
  printf '%s' "$out" | grep -q '"dataSchema"' || { echo "the catalog has no dataSchema: $out"; return 1; }
}

# M5: a token with the scope helpdesk:ticket:read only gets 403 with insufficient_scope on create_ticket.
# The audit database has the denied entry with the channel mcp.
test_mcp_denied() {
  local token out
  token="$(client_token smoke_helpdesk helpdesk "helpdesk:ticket:read")" || { echo "$token"; return 1; }
  out="$(mcp_call "$token" create_ticket '{"subject":"Denied MCP ticket","customerId":"00000000-0000-4000-8000-000000000000"}')"
  [ "$(printf '%s\n' "$out" | http_status_of)" = "403" ] || { echo "create_ticket with a read scope gave: $out"; return 1; }
  printf '%s' "$out" | grep -qi 'insufficient_scope' || { echo "no insufficient_scope in: $out"; return 1; }
  wait_audit_rows 90 "service = 'helpdesk' AND action = 'helpdesk:ticket:create' AND result = 'denied' AND actor = 'smoke_helpdesk' AND details->>'channel' = 'mcp'"
}

# M6: tools/list has 9 tools. Each tool has the required scopes in _meta.
test_mcp_tools() {
  local token out count want
  token="$(client_token smoke_helpdesk helpdesk "helpdesk:ticket:read")" || { echo "$token"; return 1; }
  out="$(mcp_raw "$token" tools/list "" "")"
  [ "$(printf '%s\n' "$out" | http_status_of)" = "200" ] || { echo "tools/list gave: $out"; return 1; }
  count="$(printf '%s' "$out" | grep -o '"name" *: *"[a-z_]*"' | grep -c -E '"(list|get|lookup|create|update)_(customers?|tickets?)"')"
  [ "$count" = "9" ] || { echo "tools/list has $count tools, not 9: $out"; return 1; }
  count="$(printf '%s' "$out" | grep -o 'ai\.techorion\.constellation/requiredScopes' | wc -l | tr -d ' ')"
  [ "$count" = "9" ] || { echo "$count tools have requiredScopes, not 9: $out"; return 1; }
  for want in '"helpdesk:customer:read"' '"helpdesk:customer:write"' '"helpdesk:ticket:read"' '"helpdesk:ticket:write"'; do
    printf '%s' "$out" | grep -qF "$want" || { echo "no scope $want in: $out"; return 1; }
  done
}

# M7: the link templates resource has the base URL and the two templates.
test_mcp_link_templates() {
  local token out want
  token="$(client_token smoke_helpdesk helpdesk "helpdesk:ticket:read")" || { echo "$token"; return 1; }
  out="$(mcp_raw "$token" resources/read "constellation://helpdesk/link-templates" "\"uri\":\"constellation://helpdesk/link-templates\"")"
  [ "$(printf '%s\n' "$out" | http_status_of)" = "200" ] || { echo "resources/read gave: $out"; return 1; }
  # The resource content is a JSON text in a string, so each quote has a backslash.
  out="${out//\\\"/\"}"
  for want in '"app":"helpdesk"' "\"baseUrl\":\"$(envval HELPDESK_PUBLIC_BASE_URL)\"" \
    '{base_url}/tickets/{id}' '{base_url}/customers/{id}'; do
    printf '%s' "$out" | tr -d ' ' | grep -qF -- "$want" || { echo "no $want in: $out"; return 1; }
  done
}

# M8: a request with no token gets 401 with resource_metadata. The metadata document is public.
test_mcp_no_token() {
  local out base
  base="$(envval HELPDESK_PUBLIC_BASE_URL)"
  out="$(mcp_raw "" tools/list "" "")"
  [ "$(printf '%s\n' "$out" | http_status_of)" = "401" ] || { echo "no token gave: $out"; return 1; }
  printf '%s' "$out" | grep -qi 'www-authenticate:.*resource_metadata' || { echo "no resource_metadata in: $out"; return 1; }
  out="$(net_http helpdesk 8080 GET /.well-known/oauth-protected-resource/mcp "" application/json)"
  [ "$(printf '%s\n' "$out" | http_status_of)" = "200" ] || { echo "metadata gave: $out"; return 1; }
  printf '%s' "$out" | tr -d ' ' | grep -qF "\"resource\":\"$base/mcp\"" || { echo "wrong resource in: $out"; return 1; }
  printf '%s' "$out" | tr -d ' ' | grep -qF "\"$(envval IDENTITY_ISSUER)\"" || { echo "wrong authorization_servers in: $out"; return 1; }
}

make_keys || { echo "FAIL: the keys of identity, events, audit, and helpdesk"; exit 1; }

# Remove a project of an earlier run.
dc down -v --remove-orphans >/dev/null 2>&1

run_check "I1: docker compose up -d and wait" test_up
if [ "${#failures[@]}" -ne 0 ]; then
  exit 1
fi

run_check "I17: ready endpoints of the collector, Loki, and Tempo" test_ready_endpoints
run_check "I2: own database, table, and advisory locks" \
  test_postgres_own smoke_a "$(envval SMOKE_A_DB_PASSWORD)"
run_check "I3: other database is refused" \
  expect_refused CONNECT pg smoke_a "$(envval SMOKE_A_DB_PASSWORD)" smoke_b -c 'SELECT 1'
run_check "I3: database postgres is refused" \
  expect_refused CONNECT pg smoke_a "$(envval SMOKE_A_DB_PASSWORD)" postgres -c 'SELECT 1'
run_check "I3: database template1 is refused" \
  expect_refused CONNECT pg smoke_a "$(envval SMOKE_A_DB_PASSWORD)" template1 -c 'SELECT 1'
run_check "I3: role has a connection limit" \
  expect_exact 50 pg smoke_a "$(envval SMOKE_A_DB_PASSWORD)" smoke_a \
  -c "SELECT rolconnlimit FROM pg_roles WHERE rolname = current_user"
run_check "I4: wrong password is refused" \
  expect_refused "password authentication failed" pg smoke_a wrong-password smoke_a -c 'SELECT 1'
run_check "I5: Valkey own prefix" \
  test_valkey_own smoke_a "$(envval SMOKE_A_VALKEY_PASSWORD)"
run_check "I6: Valkey other prefix is refused" \
  expect_output NOPERM vk smoke_a "$(envval SMOKE_A_VALKEY_PASSWORD)" SET smoke_b:k v
run_check "I7a: Valkey FLUSHALL is refused" \
  expect_output NOPERM vk smoke_a "$(envval SMOKE_A_VALKEY_PASSWORD)" FLUSHALL
run_check "I7b: Valkey CONFIG is refused" \
  expect_output NOPERM vk smoke_a "$(envval SMOKE_A_VALKEY_PASSWORD)" CONFIG GET maxmemory-policy
run_check "I20: Valkey SCAN, RANDOMKEY, DBSIZE, and MEMORY are refused" test_valkey_unfiltered_commands
run_check "I21: Valkey EVAL is refused" \
  expect_output NOPERM vk smoke_a "$(envval SMOKE_A_VALKEY_PASSWORD)" EVAL "return 1" 0
run_check "I8: Valkey appendonly and noeviction" test_valkey_settings
run_check "I18: password with a single quote" \
  test_postgres_own smoke_b "$(envval SMOKE_B_DB_PASSWORD)"
run_check "I9: provisioning again" test_reprovision
run_check "I10: Valkey restart" test_valkey_restart
run_check "I19: valkey-server is not root" test_valkey_not_root
run_check "I11: new service" test_new_service
run_check "I22: network isolation of the stores" test_network_isolation
run_check "I23: weak passwords are refused" test_weak_passwords
run_check "I12: telemetry through the collector" test_telemetry
run_check "I13: Grafana health and data sources" test_grafana
run_check "I14: Grafana without credentials" test_grafana_anonymous
run_check "I15: no password in provisioning logs" test_no_password_in_logs

run_check "I30: identity database password encoding" test_identity_password_encoding
run_check "I48: events database password encoding" test_events_password_encoding
run_check "I25: identity JWKS" test_identity_jwks
run_check "I26: identity discovery document" test_identity_discovery
run_check "I27: identity setup link record" test_identity_setup_log
run_check "I28a: identity database role cannot connect to another database" \
  expect_refused CONNECT pg identity "$(envval IDENTITY_DB_PASSWORD)" smoke_a -c 'SELECT 1'
run_check "I28b: identity Valkey user cannot read another prefix" \
  expect_output NOPERM vk identity "$(envval IDENTITY_VALKEY_PASSWORD)" GET smoke_a:k
run_check "I28c: identity Valkey user can write its prefix" \
  expect_exact OK vk identity "$(envval IDENTITY_VALKEY_PASSWORD)" SET identity:smoke 1
run_check "I32: identity login page has no upstream link with no provider" test_identity_login_no_provider
run_check "I33: identity login page has the CSP script-src 'self'" test_identity_login_csp
run_check "I34: identity unlock-login" test_identity_unlock_login
run_check "I35: identity set-idp-secret" test_identity_set_idp_secret
run_check "I29: no secret in the identity log" test_identity_no_secret_in_logs
run_check "I31: identity rate limit of GET /setup" test_identity_setup_rate_limit
run_check "I36: identity with a Google client ID" test_identity_google_enabled
run_check "I37: events is healthy" test_events_healthy
run_check "I38: events readiness endpoint" test_events_ready
run_check "I40: stream write on the own stream only" test_stream_write_own
run_check "I41: stream consume on the stream of another app" test_stream_consume smoke_a
run_check "I42: the user events has the same selectors" test_stream_events_user
run_check "I45: events database and Valkey isolation" test_events_isolation
run_check "I43: stream selectors after a Valkey restart" test_stream_after_restart
run_check "I44: stream selectors after a provisioning run" test_stream_after_reprovision
run_check "I60: bad member in audit.apps" test_audit_apps_bad_member
run_check "I47: identity with a missing clients file" test_identity_missing_clients_file
run_check "I39: events with a wrong key ID" test_events_wrong_key_id
run_check "I46: no secret in the events log" test_events_no_secret_in_logs
run_check "I49: audit is healthy and ready" test_audit_healthy
run_check "I50: audit producer selectors" test_audit_producer
run_check "I51: no audit read for a producer" test_audit_no_reader
run_check "I52: audit reader selectors" test_audit_reader
run_check "I53: audit entry from a service to the audit database" test_audit_end_to_end
run_check "I58: identity limits denied token entries" test_identity_denied_limit
run_check "I59: identity entry in the audit database" test_identity_entry_in_audit
run_check "I55: audit database and Valkey isolation" test_audit_isolation
run_check "I56: no secret in the audit log, password encoding" test_audit_no_secret_in_logs
run_check "I57: audit API refuses a request with no token" test_audit_no_token
run_check "I54: AUDIT_STREAM_READER names another user" test_audit_reader_variable
run_check "I61: no user can use audit.streams" test_no_audit_streams_access
run_check "S1: helpdesk is healthy and ready" test_helpdesk_healthy
run_check "S2: helpdesk Valkey ACL" test_helpdesk_acl
run_check "S3, S4: helpdesk customer and ticket, audit entry" test_helpdesk_create
run_check "S5: helpdesk event types in the catalog" test_helpdesk_event_types
run_check "S6: helpdesk refuses a token with a read scope" test_helpdesk_denied
run_check "S7: no secret in the helpdesk log" test_helpdesk_no_secret_in_logs
run_check "S8: helpdesk port is on 127.0.0.1" test_helpdesk_port
run_check "S9: a scope that the client does not have" test_helpdesk_invalid_scope
run_check "M1: MCP client creates a customer and a ticket" test_mcp_create
run_check "M2: MCP ticket in the audit database" test_mcp_audit
run_check "M3: MCP ticket event in the event stream" test_mcp_event
run_check "M4: ticket event type in the event catalog" test_mcp_catalog
run_check "M5: MCP refuses a token with a read scope" test_mcp_denied
run_check "M6: MCP tools and required scopes" test_mcp_tools
run_check "M7: MCP link templates resource" test_mcp_link_templates
run_check "M8: MCP refuses no token, metadata is public" test_mcp_no_token

if [ "${#failures[@]}" -ne 0 ]; then
  echo "smoke-test: ${#failures[@]} check(s) failed: ${failures[*]}"
  exit 1
fi
echo "smoke-test: all checks passed"
