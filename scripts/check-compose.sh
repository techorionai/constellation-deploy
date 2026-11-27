#!/usr/bin/env bash
# Static checks of the Compose project. No container runs.
#
# Usage: bash scripts/check-compose.sh [folder]
#
# The folder has the default ".". Checks 1 to 5 and check 7 use the files in the folder.
# Checks 6 and 8 use the scripts of this repository.
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

# 3. Each published port has the host IP 127.0.0.1. The check reads the normalized output of
# "docker compose config", so it handles each form of "ports:" (short, long, and flow syntax).
# The values of .env.example apply. The default of each host IP variable must be 127.0.0.1.
if [ -f "$compose_file" ] && [ -f "$example_file" ]; then
  while IFS='|' read -r host_ip published target; do
    if [ "$host_ip" != "127.0.0.1" ]; then
      fail port "$published:$target (host IP: ${host_ip:-none})"
    fi
  done < <(cd "$folder" && CONSTELLATION_ENV_FILE=.env.example \
    docker compose --env-file .env.example --profile '*' config 2>/dev/null | tr -d '\r' | awk '
    function flush() {
      if (have) { print host_ip "|" published "|" target }
      have = 0; host_ip = ""; published = ""; target = ""
    }
    function field(text,   key, value) {
      key = text; sub(/:.*/, "", key)
      value = text; sub(/^[^:]*:[[:space:]]*/, "", value)
      gsub(/"/, "", value); gsub(/\047/, "", value)
      if (key == "host_ip") host_ip = value
      if (key == "published") published = value
      if (key == "target") target = value
    }
    /^    ports:[[:space:]]*$/ { inports = 1; next }
    inports && /^      - / { flush(); have = 1; line = $0; sub(/^      - /, "", line); field(line); next }
    inports && /^        [a-z_]+:/ { line = $0; sub(/^ +/, "", line); field(line); next }
    { flush(); inports = 0 }
    END { flush() }
  ')
fi

# 4. Git ignores .env.
if ! grep -qx '\.env' "$folder/.gitignore" 2>/dev/null; then
  fail gitignore ".gitignore"
fi

# 5. Each password, secret, token, and key in .env.example is a placeholder.
# The variable name has the word PASSWORD, SECRET, TOKEN, or KEY between underscores.
# Six exact names hold no secret: IDENTITY_MASTER_KEY_FILE, EVENTS_CLIENT_KEY_FILE, and AUDIT_CLIENT_KEY_FILE (paths),
# IDENTITY_MASTER_KEY_ID, EVENTS_CLIENT_KEY_ID, and AUDIT_CLIENT_KEY_ID
# (identifiers). They can have any value. No other name is exempt.
secret_re='^([A-Za-z0-9_]*_)?(PASSWORD|SECRET|TOKEN|KEY)(_[A-Za-z0-9_]*)?='
if [ -f "$example_file" ]; then
  while IFS= read -r line; do
    name="${line%%=*}"
    value="${line#*=}"
    case "$name" in
      IDENTITY_MASTER_KEY_FILE | IDENTITY_MASTER_KEY_ID | EVENTS_CLIENT_KEY_FILE | EVENTS_CLIENT_KEY_ID | AUDIT_CLIENT_KEY_FILE | AUDIT_CLIENT_KEY_ID) continue ;;
    esac
    if [ "$value" != "change-me" ]; then
      fail example-secret "$name"
    fi
  done < <(grep -E "$secret_re" "$example_file" | tr -d '\r')
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
  if ! sh "$path" --check-names 'identity,audit,audit_log' >/dev/null 2>&1; then
    fail provision-names "$script.sh rejects identity,audit,audit_log"
  fi
done

# U1: the reader of the audit streams. AUDIT_STREAM_READER must be in the service list and pass
# the name rule. The check runs with no server.
reader_check() {
  # $1 = value of AUDIT_STREAM_READER, or "unset". $2 = service list. $3 = expected exit code.
  local code
  if [ "$1" = "unset" ]; then
    env -u AUDIT_STREAM_READER sh "$repo_root/provision/valkey.sh" --check-names "$2" >/dev/null 2>&1
  else
    AUDIT_STREAM_READER="$1" sh "$repo_root/provision/valkey.sh" --check-names "$2" >/dev/null 2>&1
  fi
  code=$?
  if [ "$code" -ne "$3" ]; then
    fail provision-reader "AUDIT_STREAM_READER=$1 with $2 gave exit code $code"
  fi
}
reader_check unset identity,events,audit 0
reader_check '' identity,events,audit 0
reader_check crm identity,events,audit 1
reader_check Bad identity,events,audit 1
reader_check unset identity,events 1
for reader_value in crm Bad; do
  if ! AUDIT_STREAM_READER="$reader_value" sh "$repo_root/provision/valkey.sh" --check-names identity,events,audit 2>&1 | grep -q AUDIT_STREAM_READER; then
    fail provision-reader "the message for AUDIT_STREAM_READER=$reader_value does not name AUDIT_STREAM_READER"
  fi
done
if ! env -u AUDIT_STREAM_READER sh "$repo_root/provision/valkey.sh" --check-names identity,events 2>&1 | grep -q AUDIT_STREAM_READER; then
  fail provision-reader "the message for a reader that is not in the list does not name AUDIT_STREAM_READER"
fi

# 7. No shell file has a CR character.
while IFS= read -r -d '' file; do
  if has_cr "$file"; then
    fail crlf "${file#"$folder"/}"
  fi
done < <(find "$folder" -name '*.sh' -not -path '*/.git/*' -print0)

# 8. The password rules of the scripts reject the placeholder, short values, and white space.
# shellcheck source=/dev/null
(. "$repo_root/provision/check-password.sh"
  [ "$MIN_PASSWORD_LENGTH" -ge 12 ] || exit 1
  ! check_password TEST_PASSWORD "change-me" 2>/dev/null || exit 1
  ! check_password TEST_PASSWORD "my-change-me-password" 2>/dev/null || exit 1
  ! check_password TEST_PASSWORD "" 2>/dev/null || exit 1
  ! check_password TEST_PASSWORD "short" 2>/dev/null || exit 1
  check_password TEST_PASSWORD "a-long-enough-test-value" 2>/dev/null || exit 1
  ! check_no_whitespace TEST_PASSWORD "has a space" 2>/dev/null || exit 1
  ! check_no_whitespace TEST_PASSWORD "has"$'\n'"newline" 2>/dev/null || exit 1
  check_no_whitespace TEST_PASSWORD "no-space-here" 2>/dev/null || exit 1
) || fail password-rules "provision/check-password.sh"

# 9. Identity and events set the retention of the audit stream. Without it, the image default of
# 168h applies and failed token requests can fill the Valkey memory. The check applies only
# if the Compose file runs the identity image or the events image.
if [ -f "$compose_file" ]; then
  for pair in "constellation-identity:IDENTITY_RETENTION__AUDIT_STREAM__PERIOD" "constellation-events:EVENTS_RETENTION__AUDIT_STREAM__PERIOD"; do
    img="${pair%%:*}"
    var="${pair#*:}"
    if grep -qE "image:.*/$img:" "$compose_file" && ! grep -qE "^[[:space:]]+$var:[[:space:]]*[^[:space:]]" "$compose_file"; then
      fail audit-retention "$var"
    fi
  done
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-compose: all checks passed"
