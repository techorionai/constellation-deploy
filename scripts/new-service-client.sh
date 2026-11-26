#!/usr/bin/env bash
# Make a client key pair for a service and add the client entry to the identity clients file.
#
# Usage:
#   bash scripts/new-service-client.sh [--secrets-dir DIR] [--clients-file FILE] [--kid KID]
#     [--rotate] <svc> [role ...]
#
# A role has the form <app>:<role>, for example events:producer.
# The script makes an EC P-256 private key (PKCS #8 PEM, mode 0400) and the public JWK.
# Without --rotate, it adds the client entry to the clients file. The file can be:
#   - no file
#   - a file with the line "clients: []"
#   - a file with the line "clients:" and block list entries that start with "  - id: "
# Each other form is refused and the script changes nothing.
# With --rotate, the script makes a new key and prints the "keys" entry. It does not change
# the clients file. The operator adds the printed entry.
# The script does not read .env and does not use sudo.
set -euo pipefail

# The C locale makes the ranges a-z in the checks match lowercase letters only.
export LC_ALL=C

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"

secrets_dir="./secrets"
clients_file=""
kid=""
rotate=0
cr=$'\r'
bad_form="the clients file has a form that this script does not change. Add the entry by hand."

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  echo "Usage: bash scripts/new-service-client.sh [--secrets-dir DIR] [--clients-file FILE] [--kid KID] [--rotate] <svc> [role ...]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --secrets-dir) [ "$#" -ge 2 ] || usage; secrets_dir="$2"; shift 2 ;;
    --clients-file) [ "$#" -ge 2 ] || usage; clients_file="$2"; shift 2 ;;
    --kid) [ "$#" -ge 2 ] || usage; kid="$2"; shift 2 ;;
    --rotate) rotate=1; shift ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ "$#" -ge 1 ] || usage
svc="$1"
shift
roles=("$@")
[ -n "$clients_file" ] || clients_file="$secrets_dir/identity-clients.yaml"

# Check all input before the script changes anything.
[ -n "$svc" ] || die "the service name is empty"
case "$svc" in
  *,*) die "bad service name: $svc" ;;
  identity) die "the name identity is not allowed for a service client" ;;
esac
sh "$repo_root/provision/valkey.sh" --check-names "$svc" 2>/dev/null || die "bad service name: $svc"
[ -n "$kid" ] || kid="$svc-1"
[[ "$kid" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || die "bad key ID: $kid"
for role in "${roles[@]+"${roles[@]}"}"; do
  [[ "$role" =~ ^[a-z][a-z0-9_]{0,31}:[a-z][a-z0-9_]*$ ]] || die "bad role: $role"
done
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

if [ "$rotate" -eq 1 ]; then
  key_file="$secrets_dir/$svc-client-key-$kid.pem"
else
  key_file="$secrets_dir/$svc-client-key.pem"
fi
[ ! -e "$key_file" ] || die "the key file exists: $key_file"

# Examine the clients file form. The variable form is none, empty, or block.
form=none
if [ "$rotate" -eq 0 ] && [ -e "$clients_file" ]; then
  [ -f "$clients_file" ] || die "the clients path is not a file: $clients_file"
  header=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%"$cr"}"
    case "$line" in
      '' | '#'* | [[:space:]]*'#'*) continue ;;
    esac
    if [ -z "$header" ]; then
      header="$line"
      case "$header" in
        'clients: []') form=empty ;;
        'clients:') form=block ;;
        *) die "$bad_form" ;;
      esac
    elif [ "$form" = empty ]; then
      die "$bad_form"
    else
      case "$line" in
        ' '*) ;;
        *) die "$bad_form" ;;
      esac
    fi
  done < "$clients_file"
  [ -n "$header" ] || die "the clients file has no clients line. Add the entry by hand."
  if grep -Eq "^  - id: \"?$svc\"?[[:space:]]*\$" "$clients_file"; then
    die "the clients file has the client $svc already. Use --rotate for a new key."
  fi
fi

umask 077
mkdir -p "$secrets_dir"
# The key file can get the mode 0444 on Docker Desktop. That is safe only if the folder has no
# permission for group and other. A new folder has the mode 0700, but an old folder can differ.
dir_mode="$(stat -c %a "$secrets_dir" 2>/dev/null || stat -f %Lp "$secrets_dir" 2>/dev/null)" \
  || die "could not read the mode of the folder $secrets_dir"
[ "${dir_mode: -2}" = "00" ] \
  || die "the folder $secrets_dir has the mode $dir_mode. It must have the mode 0700: run chmod 0700 $secrets_dir"
tmp_key="$(mktemp "$secrets_dir/.new-key.XXXXXX")"
tmp_clients=""
cleanup() {
  rm -f "$tmp_key"
  if [ -n "$tmp_clients" ]; then
    rm -f "$tmp_clients"
  fi
}
trap cleanup EXIT

# A native Windows openssl needs a Windows path. Git Bash gives one with cygpath.
ssl_key="$tmp_key"
if command -v cygpath >/dev/null 2>&1; then
  ssl_key="$(cygpath -m "$tmp_key")"
fi
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ssl_key" 2>/dev/null \
  || die "openssl could not make the key"

# Encode hex text as base64url with no padding.
hex_b64url() {
  local hex="$1" i bytes=""
  for ((i = 0; i < ${#hex}; i += 2)); do
    bytes="$bytes\\x${hex:i:2}"
  done
  # shellcheck disable=SC2059
  printf "$bytes" | openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# The last 64 bytes of the DER public key are x (32 bytes) and y (32 bytes).
point="$(openssl pkey -in "$ssl_key" -pubout -outform DER | tail -c 64 | od -An -v -tx1 | tr -d ' \n')"
[ "${#point}" -eq 128 ] || die "could not read the public key"
x="$(hex_b64url "${point:0:64}")"
y="$(hex_b64url "${point:64:64}")"
{ [ "${#x}" -eq 43 ] && [ "${#y}" -eq 43 ]; } || die "could not encode the public key"

jwk="{kty: EC, crv: P-256, x: \"$x\", y: \"$y\"}"
roles_text=""
for role in "${roles[@]+"${roles[@]}"}"; do
  roles_text="${roles_text:+$roles_text, }$role"
done

if [ "$rotate" -eq 0 ]; then
  entry="  - id: $svc
    app: $svc
    name: $svc
    keys:
      - kid: $kid
        jwk: $jwk
    roles: [$roles_text]"
  clients_dir="$(dirname "$clients_file")"
  mkdir -p "$clients_dir"
  tmp_clients="$(mktemp "$clients_dir/.clients.XXXXXX")"
  case "$form" in
    none)
      printf 'clients:\n%s\n' "$entry" > "$tmp_clients"
      ;;
    empty)
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%"$cr"}"
        if [ "$line" = 'clients: []' ]; then
          printf 'clients:\n'
        else
          printf '%s\n' "$line"
        fi
      done < "$clients_file" > "$tmp_clients"
      printf '%s\n' "$entry" >> "$tmp_clients"
      ;;
    block)
      cp "$clients_file" "$tmp_clients"
      if [ -s "$tmp_clients" ] && [ "$(tail -c 1 "$tmp_clients" | od -An -tx1 | tr -d ' ')" != "0a" ]; then
        printf '\n' >> "$tmp_clients"
      fi
      printf '%s\n' "$entry" >> "$tmp_clients"
      ;;
  esac
  chmod 0644 "$tmp_clients"
fi

# Put the key file in place first. Then put the clients file in place. If the second step fails,
# remove the new key file, so the clients file never has an entry with no key file.
chmod 0400 "$tmp_key"
mv "$tmp_key" "$key_file"
if [ -n "$tmp_clients" ]; then
  if ! mv "$tmp_clients" "$clients_file"; then
    rm -f "$key_file"
    die "could not write the clients file $clients_file. The new key file was removed."
  fi
  tmp_clients=""
fi

echo "Key file: $key_file"
echo "Key ID: $kid"
if [ "$rotate" -eq 1 ]; then
  echo "Add this entry to the keys of the client $svc in the clients file. The script does not change the clients file."
  echo "      - kid: $kid"
  echo "        jwk: $jwk"
else
  echo "Clients file: $clients_file"
fi
upper="$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')"
echo "Next steps:"
echo "  1. Set the owner of the key file for the container user:"
echo "       sudo chown 65532:65532 $key_file"
echo "     On Docker Desktop, where the owner cannot change, use chmod 0444 on the key file"
echo "     and keep the mode 0700 on the folder $secrets_dir."
echo "  2. Set ${upper}_CLIENT_KEY_FILE and ${upper}_CLIENT_KEY_ID=$kid in the env file."
echo "  3. Restart identity (it reads the clients file only at the start), then the service."
