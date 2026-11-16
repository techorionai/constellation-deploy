#!/bin/sh
# Make one Valkey ACL user for each name in CONSTELLATION_SERVICES.
# The script is idempotent. The "reset" keyword gives the same result on a second run.
#
# Usage:
#   sh provision/valkey.sh                       Provision the services.
#   sh provision/valkey.sh --check-names <list>  Check the names. No server.
set -eu

# A service name is a PostgreSQL role and a Valkey user. Both scripts use the same rule.
# The name "default" is the Valkey admin user. A name check that accepts it
# would let "ACL SETUSER default reset ..." replace the admin password.
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

: "${VALKEY_ADMIN_PASSWORD:?VALKEY_ADMIN_PASSWORD is not set}"
services="${CONSTELLATION_SERVICES:-}"
check_list "$services" || exit 1

# valkey-cli reads the admin password from this variable. The -a flag is not used.
export REDISCLI_AUTH="$VALKEY_ADMIN_PASSWORD"

cli() {
  valkey-cli -h valkey "$@"
}

expect_ok() {
  if [ "$1" != "OK" ]; then
    echo "ERROR: valkey: unexpected reply: $1" >&2
    exit 1
  fi
}

provision() {
  svc="$1"
  upper=$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')
  pw=$(printenv "${upper}_VALKEY_PASSWORD" || true)
  if [ -z "$pw" ]; then
    echo "ERROR: ${upper}_VALKEY_PASSWORD is not set" >&2
    return 1
  fi
  reply=$(cli ACL SETUSER "$svc" reset on ">$pw" "~$svc:*" \
    +@all -@admin -@dangerous -function "-script|flush" "-script|kill")
  expect_ok "$reply"
  echo "valkey: provisioned $svc"
}

if [ -z "$services" ]; then
  echo "valkey: no services in CONSTELLATION_SERVICES"
  exit 0
fi

rest="$services,"
while [ -n "$rest" ]; do
  name="${rest%%,*}"
  rest="${rest#*,}"
  provision "$name"
done

# Write the users to the ACL file in the valkey-data volume. The users stay after a restart.
reply=$(cli ACL SAVE)
expect_ok "$reply"
