#!/bin/sh
# Entrypoint of the valkey service.
# If the ACL file does not exist, write the "default" (admin) user with VALKEY_ADMIN_PASSWORD.
# The script does not use --requirepass, because requirepass and an ACL file conflict.
# The image entrypoint then changes the owner of /data and starts valkey-server
# as the valkey user. Thus valkey-server does not run as root.
set -eu

: "${VALKEY_ADMIN_PASSWORD:?VALKEY_ADMIN_PASSWORD is not set}"

acl_file=/data/acl/users.acl
if [ ! -f "$acl_file" ]; then
  mkdir -p /data/acl
  umask 077
  printf 'user default on >%s ~* &* +@all\n' "$VALKEY_ADMIN_PASSWORD" > "$acl_file"
fi

exec docker-entrypoint.sh valkey-server "$@"
