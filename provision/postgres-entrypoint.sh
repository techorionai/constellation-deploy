#!/bin/sh
# Entrypoint of the postgres service.
# Reject a weak admin password before the image entrypoint starts PostgreSQL.
set -eu

# shellcheck source=/dev/null
. "$(dirname "$0")/check-password.sh"

check_password POSTGRES_PASSWORD "${POSTGRES_PASSWORD:-}" || exit 1

exec docker-entrypoint.sh "$@"
