#!/bin/sh
# Entrypoint of the grafana service.
# Reject a weak admin password or secret key before Grafana starts.
set -eu

# shellcheck source=/dev/null
. "$(dirname "$0")/check-password.sh"

check_password GRAFANA_ADMIN_PASSWORD "${GF_SECURITY_ADMIN_PASSWORD:-}" || exit 1
check_password GRAFANA_SECRET_KEY "${GF_SECURITY_SECRET_KEY:-}" || exit 1

exec /run.sh "$@"
