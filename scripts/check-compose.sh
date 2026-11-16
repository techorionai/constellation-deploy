#!/usr/bin/env bash
# Static checks of the Compose project. No container runs.
#
# Usage: bash scripts/check-compose.sh [folder]
#
# The folder has the default ".". Checks 1 to 5 and check 7 use the files in the folder.
# Check 6 uses the scripts of this repository.
# Each failed check prints "ERROR: <check>: <file or value>". The exit code is 1.
set -u

folder="${1:-.}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0

fail() {
  echo "ERROR: $1: $2"
  failed=1
}

# True if the file has a CR character. Plain grep on Windows hides the CR character.
has_cr() {
  local content
  content="$(cat "$1")"
  [[ "$content" == *$'\r'* ]]
}

compose_file="$folder/compose.yaml"
example_file="$folder/.env.example"

# 1. The Compose file is valid, also with all profiles.
if [ ! -f "$compose_file" ]; then
  fail compose-config "compose.yaml"
elif [ ! -f "$example_file" ]; then
  fail compose-config ".env.example"
else
  if ! (cd "$folder" && CONSTELLATION_ENV_FILE=.env.example \
    docker compose --env-file .env.example config --quiet); then
    fail compose-config "compose.yaml"
  fi
  if ! (cd "$folder" && CONSTELLATION_ENV_FILE=.env.example \
    docker compose --env-file .env.example --profile '*' config --quiet); then
    fail compose-config "compose.yaml (all profiles)"
  fi
fi

# 2. Each image has an exact tag or a digest.
tag_re='^v?[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9.]+)?$'
digest_re='@sha256:[0-9a-f]{64}$'
if [ -f "$compose_file" ]; then
  while IFS= read -r line; do
    image="${line#*image:}"
    image="${image//\"/}"
    image="${image//\'/}"
    image="${image#"${image%%[![:space:]]*}"}"
    image="${image%"${image##*[![:space:]]}"}"
    if [[ "$image" =~ $digest_re ]]; then
      continue
    fi
    last="${image##*/}"
    if [[ "$last" != *:* ]]; then
      fail image "$image"
      continue
    fi
    tag="${last##*:}"
    if ! [[ "$tag" =~ $tag_re ]]; then
      fail image "$image"
    fi
  done < <(grep -E '^[[:space:]]+image:' "$compose_file")
fi

# 3. Each published port has a host IP from a variable with the default 127.0.0.1.
port_re='^\$\{[A-Z][A-Z0-9_]*:-127\.0\.0\.1\}:'
if [ -f "$compose_file" ]; then
  while IFS= read -r item; do
    item="${item//\"/}"
    item="${item//\'/}"
    if ! [[ "$item" =~ $port_re ]]; then
      fail port "$item"
    fi
  done < <(awk '
    /^[[:space:]]*ports:[[:space:]]*$/ { inports = 1; next }
    inports && /^[[:space:]]*-/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); print; next }
    inports && /^[[:space:]]*$/ { next }
    { inports = 0 }
  ' "$compose_file")
fi

# 4. Git ignores .env.
if ! grep -qx '\.env' "$folder/.gitignore" 2>/dev/null; then
  fail gitignore ".gitignore"
fi

# 5. Each password in .env.example is a placeholder.
if [ -f "$example_file" ]; then
  while IFS= read -r line; do
    name="${line%%=*}"
    value="${line#*=}"
    if [ "$value" != "change-me" ]; then
      fail example-password "$name"
    fi
  done < <(grep -E '^[A-Za-z0-9_]*_PASSWORD=' "$example_file")
fi

# 6. The provisioning scripts reject bad service names.
bad_names=(Bad-Name postgres template0 template1 public default pg_monitor 'a;drop'
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 'identity,default' 'identity,')
for script in postgres valkey; do
  path="$repo_root/provision/$script.sh"
  for name in "${bad_names[@]}"; do
    if sh "$path" --check-names "$name" >/dev/null 2>&1; then
      fail provision-names "$script.sh accepts $name"
    fi
  done
  if ! sh "$path" --check-names 'identity,audit_log' >/dev/null 2>&1; then
    fail provision-names "$script.sh rejects identity,audit_log"
  fi
done

# 7. No shell file has a CR character.
while IFS= read -r -d '' file; do
  if has_cr "$file"; then
    fail crlf "${file#"$folder"/}"
  fi
done < <(find "$folder" -name '*.sh' -not -path '*/.git/*' -print0)

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-compose: all checks passed"
