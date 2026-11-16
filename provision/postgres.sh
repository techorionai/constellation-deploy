#!/bin/sh
# Make one PostgreSQL role and one database for each name in CONSTELLATION_SERVICES.
# The script is idempotent. A second run gives the same result.
#
# Usage:
#   sh provision/postgres.sh                       Provision the services.
#   sh provision/postgres.sh --check-names <list>  Check the names. No server.
set -eu

# A service name is a PostgreSQL role and a Valkey user. Both scripts use the same rule.
check_name() {
  case "$1" in
    '' | [!a-z]* | *[!a-z0-9_]*) return 1 ;;
    default | public | postgres | template0 | template1 | pg_*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

# Check each name of a comma-separated list. An empty list is valid.
check_list() {
  [ -n "$1" ] || return 0
  rest="$1,"
  while [ -n "$rest" ]; do
    name="${rest%%,*}"
    rest="${rest#*,}"
    if ! check_name "$name"; then
      echo "ERROR: bad service name: $name" >&2
      return 1
    fi
  done
}

if [ "${1:-}" = "--check-names" ]; then
  check_list "${2:-}"
  exit $?
fi

: "${POSTGRES_USER:?POSTGRES_USER is not set}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
services="${CONSTELLATION_SERVICES:-}"
check_list "$services" || exit 1

export PGPASSWORD="$POSTGRES_PASSWORD"

provision() {
  svc="$1"
  upper=$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')
  pw=$(printenv "${upper}_DB_PASSWORD" || true)
  if [ -z "$pw" ]; then
    echo "ERROR: ${upper}_DB_PASSWORD is not set" >&2
    return 1
  fi
  # The psql variables and format() quote the values. A value cannot inject SQL.
  psql -h postgres -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -q \
    -v name="$svc" -v pw="$pw" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'name')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'name') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'name', :'pw') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'name', :'name')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'name') \gexec
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'name') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'name', :'name') \gexec
SQL
  echo "postgres: provisioned $svc"
}

if [ -z "$services" ]; then
  echo "postgres: no services in CONSTELLATION_SERVICES"
  exit 0
fi

rest="$services,"
while [ -n "$rest" ]; do
  name="${rest%%,*}"
  rest="${rest#*,}"
  provision "$name"
done
