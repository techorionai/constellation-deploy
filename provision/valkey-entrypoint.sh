#!/bin/sh
# Entrypoint of the valkey service.
# If the ACL file does not exist, write the "default" (admin) user with the SHA-256 hash of
# VALKEY_ADMIN_PASSWORD. The file never has the password in plain text.
# The script does not use --requirepass, because requirepass and an ACL file conflict.
# The image entrypoint then changes the owner of /data and starts valkey-server
# as the valkey user. Thus valkey-server does not run as root.
set -eu

# shellcheck source=/dev/null
. "$(dirname "$0")/check-password.sh"

check_password VALKEY_ADMIN_PASSWORD "${VALKEY_ADMIN_PASSWORD:-}" || exit 1
check_no_whitespace VALKEY_ADMIN_PASSWORD "$VALKEY_ADMIN_PASSWORD" || exit 1

acl_file=/data/acl/users.acl
if [ ! -f "$acl_file" ]; then
  mkdir -p /data/acl
  umask 077
  hash=$(printf '%s' "$VALKEY_ADMIN_PASSWORD" | sha256sum | cut -d' ' -f1)
  printf 'user default on #%s ~* &* +@all\n' "$hash" > "$acl_file"
fi

exec docker-entrypoint.sh valkey-server "$@"
