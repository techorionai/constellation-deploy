#!/bin/sh
# Make one Valkey ACL user for each name in CONSTELLATION_SERVICES.
# The script is idempotent. The "reset" keyword gives the same result on a second run.
#
# Usage:
#   sh provision/valkey.sh                       Provision the services.
#   sh provision/valkey.sh --check-names <list>  Check the names. No server.
set -eu

# shellcheck source=/dev/null
. "$(dirname "$0")/check-password.sh"

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

services="${CONSTELLATION_SERVICES:-}"
check_list "$services" || exit 1

# Examine each password before the script changes anything.
check_password VALKEY_ADMIN_PASSWORD "${VALKEY_ADMIN_PASSWORD:-}" || exit 1
check_no_whitespace VALKEY_ADMIN_PASSWORD "$VALKEY_ADMIN_PASSWORD" || exit 1
rest="$services,"
while [ -n "$services" ] && [ -n "$rest" ]; do
  name="${rest%%,*}"
  rest="${rest#*,}"
  upper=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
  pw=$(printenv "${upper}_VALKEY_PASSWORD" || true)
  check_password "${upper}_VALKEY_PASSWORD" "$pw" || exit 1
  check_no_whitespace "${upper}_VALKEY_PASSWORD" "$pw" || exit 1
done

# valkey-cli reads the admin password from this variable. The -a flag is not used.
export REDISCLI_AUTH="$VALKEY_ADMIN_PASSWORD"

# The commands go to valkey-cli through stdin, not as arguments.
cli() {
  printf '%s\n' "$1" | valkey-cli -h valkey
}

expect_ok() {
  if [ "$1" != "OK" ]; then
    echo "ERROR: valkey: unexpected reply: $1" >&2
    exit 1
  fi
}

# The ACL rule has the SHA-256 hash of the password, not the password. The rule is the
# ACL of the platform: own key prefix only, no admin or dangerous commands, no scripts,
# and no command that Valkey does not filter by key pattern (SCAN, RANDOMKEY, DBSIZE, MEMORY).
provision() {
  svc="$1"
  upper=$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')
  pw=$(printenv "${upper}_VALKEY_PASSWORD" || true)
  hash=$(printf '%s' "$pw" | sha256sum | cut -d' ' -f1)
  reply=$(cli "ACL SETUSER $svc reset on #$hash ~$svc:* +@all -@admin -@dangerous -@scripting -function -scan -randomkey -dbsize -memory")
  expect_ok "$reply"
  echo "valkey: provisioned $svc"
}

if [ -z "$services" ]; then
  echo "valkey: no services in CONSTELLATION_SERVICES"
else
  rest="$services,"
  while [ -n "$rest" ]; do
    name="${rest%%,*}"
    rest="${rest#*,}"
    provision "$name"
  done
fi

# Write the users to the ACL file in the valkey-data volume. The users stay after a restart.
# This also replaces an old ACL file that has the admin password in plain text.
reply=$(cli "ACL SAVE")
expect_ok "$reply"
