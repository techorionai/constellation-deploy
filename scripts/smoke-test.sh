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
  for service in postgres valkey prometheus grafana identity; do
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
    -e 's|^CONSTELLATION_SERVICES=.*|CONSTELLATION_SERVICES=smoke_a,smoke_b,smoke_c|' \
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

# Make the master key of identity in a temporary folder with the procedure of docs/compose.md.
# The folder has mode 0700 and the file has mode 0444, so the container user can read it.
# The script exports the path. A shell variable overrides the env file.
make_master_key() {
  key_dir="$(mktemp -d)" || return 1
  chmod 0700 "$key_dir"
  openssl rand -base64 32 > "$key_dir/identity-master-key" || return 1
  chmod 0444 "$key_dir/identity-master-key"
  # Docker on Windows needs a Windows path. Git Bash gives one with cygpath.
  if command -v cygpath >/dev/null 2>&1; then
    IDENTITY_MASTER_KEY_FILE="$(cygpath -m "$key_dir")/identity-master-key"
  else
    IDENTITY_MASTER_KEY_FILE="$key_dir/identity-master-key"
  fi
  export IDENTITY_MASTER_KEY_FILE
}

# Read a URL from the container postgres. It is in the network "services", like a business service.
svc_get() {
  dc exec -T postgres wget -q -T 10 -O - "$1"
}

# I30: the URL-encoded database password decodes to the database password. The password has
# characters that need encoding, so a wrong encoded value stops identity from connecting.
test_identity_password_encoding() {
  local plain encoded decoded
  plain="$(envval IDENTITY_DB_PASSWORD)"
  encoded="$(envval IDENTITY_DB_PASSWORD_URLENCODED)"
  if [ "$plain" = "$encoded" ]; then
    echo "the test password does not need encoding"
    return 1
  fi
  decoded="$(printf '%b' "${encoded//%/\\x}")"
  if [ "$decoded" != "$plain" ]; then
    echo "the encoded password does not decode to IDENTITY_DB_PASSWORD"
    return 1
  fi
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

make_master_key || { echo "FAIL: the master key of identity"; exit 1; }

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
run_check "I25: identity JWKS" test_identity_jwks
run_check "I26: identity discovery document" test_identity_discovery
run_check "I27: identity setup link record" test_identity_setup_log
run_check "I28a: identity database role cannot connect to another database" \
  expect_refused CONNECT pg identity "$(envval IDENTITY_DB_PASSWORD)" smoke_a -c 'SELECT 1'
run_check "I28b: identity Valkey user cannot read another prefix" \
  expect_output NOPERM vk identity "$(envval IDENTITY_VALKEY_PASSWORD)" GET smoke_a:k
run_check "I28c: identity Valkey user can write its prefix" \
  expect_exact OK vk identity "$(envval IDENTITY_VALKEY_PASSWORD)" SET identity:smoke 1
run_check "I29: no secret in the identity log" test_identity_no_secret_in_logs
run_check "I31: identity rate limit of GET /setup" test_identity_setup_rate_limit

if [ "${#failures[@]}" -ne 0 ]; then
  echo "smoke-test: ${#failures[@]} check(s) failed: ${failures[*]}"
  exit 1
fi
echo "smoke-test: all checks passed"
