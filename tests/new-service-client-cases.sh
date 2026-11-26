#!/usr/bin/env bash
# Tests of scripts/new-service-client.sh (U4 to U11). The tests need openssl. They need no Docker.
# Each case runs the script in a new temporary folder outside the repository.
set -u
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/new-service-client.sh"
failed=0
work=""

# shellcheck disable=SC2329
cleanup() {
  if [ -n "$work" ]; then
    chmod -R u+w "$work" 2>/dev/null
    rm -rf "$work"
  fi
}
trap cleanup EXIT
work="$(mktemp -d)"

pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1: $2"; failed=1; }

# Run the script in the folder $1 with the remaining arguments. Use the umask 000.
run() {
  local dir="$1"
  shift
  (umask 000 && cd "$dir" && bash "$script" "$@") 2>&1
}

fresh() {
  local d
  d="$(mktemp -d "$work/case.XXXXXX")"
  echo "$d"
}

mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# The public point of a key as hex text. It is the text after the "04" prefix.
point_hex() {
  openssl pkey -in "$1" -text -noout | sed -n '/^pub:/,/^ASN1/p' | grep -E '^ +[0-9a-f:]+$' \
    | tr -d ' :\n' | cut -c3-
}

# The hex text of a base64url value.
b64url_hex() {
  local v="$1"
  while [ $(( ${#v} % 4 )) -ne 0 ]; do v="$v="; done
  printf '%s' "$v" | tr '_-' '/+' | openssl base64 -d -A | od -An -v -tx1 | tr -d ' \n'
}

# U4: bad names are refused and nothing is made. An existing key file is refused.
d="$(fresh)"
ok=1
for name in Bad-Name default identity ""; do
  if run "$d" --secrets-dir s "$name" >/dev/null; then ok=0; fi
done
if [ "$ok" -eq 1 ] && [ ! -e "$d/s" ]; then pass "U4: bad names"; else fail "U4: bad names" "a bad name was accepted or a file was made"; fi
d="$(fresh)"
mkdir "$d/s"
echo old > "$d/s/helpdesk-client-key.pem"
if ! run "$d" --secrets-dir s helpdesk >/dev/null && [ "$(cat "$d/s/helpdesk-client-key.pem")" = old ] \
  && [ ! -e "$d/s/identity-clients.yaml" ]; then
  pass "U4: existing key file"
else
  fail "U4: existing key file" "the script did not refuse, or it changed a file"
fi

# U5: a key and an entry.
d="$(fresh)"
out="$(run "$d" --secrets-dir s helpdesk events:producer)" || fail "U5" "$out"
key="$d/s/helpdesk-client-key.pem"
clients="$d/s/identity-clients.yaml"
if [ "$(mode_of "$key")" = "400" ] || [ "$(mode_of "$key")" = "444" ]; then
  # Git Bash on Windows shows 444 for a read-only file.
  pass "U5: key mode"
else
  fail "U5: key mode" "$(mode_of "$key")"
fi
if [ "$(mode_of "$clients")" = "644" ]; then pass "U5: clients file mode"; else fail "U5: clients file mode" "$(mode_of "$clients")"; fi
if openssl pkey -in "$key" -noout 2>/dev/null; then pass "U5: key is readable"; else fail "U5: key is readable" "openssl cannot read the key"; fi
for want in '  - id: helpdesk' '    app: helpdesk' '    name: helpdesk' '      - kid: helpdesk-1' 'roles: [events:producer]' \
  'kty: EC' 'crv: P-256'; do
  grep -qF -- "$want" "$clients" || fail "U5: entry" "missing: $want"
done
x="$(sed -n 's/.*x: "\([^"]*\)".*/\1/p' "$clients")"
y="$(sed -n 's/.*y: "\([^"]*\)".*/\1/p' "$clients")"
if [ "${#x}" -eq 43 ] && [ "${#y}" -eq 43 ] \
  && [ "$(b64url_hex "$x")$(b64url_hex "$y")" = "$(point_hex "$key")" ]; then
  pass "U5: JWK matches the key"
else
  fail "U5: JWK matches the key" "x=$x y=$y"
fi
if printf '%s' "$out" | grep -q 'PRIVATE KEY'; then fail "U5: output" "the output has key text"; fi

# U6: a duplicate id is refused. The clients file does not change. No key file is made.
before="$(cat "$clients")"
if ! out="$(run "$d" --secrets-dir s2 --clients-file s/identity-clients.yaml --kid helpdesk-2 helpdesk)" \
  && [ "$(cat "$clients")" = "$before" ] && [ ! -e "$d/s2/helpdesk-client-key.pem" ]; then
  pass "U6: duplicate id"
else
  fail "U6: duplicate id" "$out"
fi

# U7: bad roles are refused. No file is made.
d="$(fresh)"
ok=1
for role in Events:Producer events 'events:'; do
  if run "$d" --secrets-dir s helpdesk "$role" >/dev/null; then ok=0; fi
done
if [ "$ok" -eq 1 ] && [ ! -e "$d/s/helpdesk-client-key.pem" ] && [ ! -e "$d/s/identity-clients.yaml" ]; then
  pass "U7: bad roles"
else
  fail "U7: bad roles" "a bad role was accepted or a file was made"
fi

# U8: the forms "clients: []" and a block list.
d="$(fresh)"
mkdir "$d/s"
printf '# Comment line\nclients: []\n' > "$d/s/identity-clients.yaml"
if run "$d" --secrets-dir s helpdesk >/dev/null \
  && [ "$(sed -n 1p "$d/s/identity-clients.yaml")" = "# Comment line" ] \
  && [ "$(sed -n 2p "$d/s/identity-clients.yaml")" = "clients:" ] \
  && grep -qF '  - id: helpdesk' "$d/s/identity-clients.yaml" \
  && ! grep -qxF 'clients: []' "$d/s/identity-clients.yaml"; then
  pass "U8: empty list"
else
  fail "U8: empty list" "$(cat "$d/s/identity-clients.yaml")"
fi
d="$(fresh)"
mkdir "$d/s"
old='clients:
  - id: other
    app: other
    name: other
    keys: []
    roles: []'
printf '%s\n' "$old" > "$d/s/identity-clients.yaml"
if run "$d" --secrets-dir s helpdesk >/dev/null \
  && [ "$(head -n 6 "$d/s/identity-clients.yaml")" = "$old" ] \
  && grep -qF '  - id: helpdesk' "$d/s/identity-clients.yaml"; then
  pass "U8: block list"
else
  fail "U8: block list" "$(cat "$d/s/identity-clients.yaml")"
fi

# U9: a flow list is refused. The file does not change.
d="$(fresh)"
mkdir "$d/s"
printf 'clients: [{id: x, app: x}]\n' > "$d/s/identity-clients.yaml"
if ! run "$d" --secrets-dir s helpdesk >/dev/null \
  && [ "$(cat "$d/s/identity-clients.yaml")" = 'clients: [{id: x, app: x}]' ] \
  && [ ! -e "$d/s/helpdesk-client-key.pem" ]; then
  pass "U9: flow list"
else
  fail "U9: flow list" "the script did not refuse, or it changed a file"
fi

# U10: --rotate makes a new key and prints the entry. The clients file does not change.
d="$(fresh)"
run "$d" --secrets-dir s helpdesk >/dev/null || fail "U10" "setup"
before="$(cat "$d/s/identity-clients.yaml")"
out="$(run "$d" --secrets-dir s --rotate --kid helpdesk-2 helpdesk)" || fail "U10" "$out"
rkey="$d/s/helpdesk-client-key-helpdesk-2.pem"
if [ -f "$rkey" ] && { [ "$(mode_of "$rkey")" = "400" ] || [ "$(mode_of "$rkey")" = "444" ]; } \
  && printf '%s' "$out" | grep -qF -- '- kid: helpdesk-2' \
  && [ "$(cat "$d/s/identity-clients.yaml")" = "$before" ]; then
  pass "U10: rotate"
else
  fail "U10: rotate" "$out"
fi
if ! run "$d" --secrets-dir s --rotate --kid helpdesk-2 helpdesk >/dev/null; then
  pass "U10: second rotate is refused"
else
  fail "U10: second rotate is refused" "the script accepted the same key ID"
fi

# U11: a bad key ID is refused. No file is made.
d="$(fresh)"
if ! run "$d" --secrets-dir s --kid "Bad Kid" helpdesk >/dev/null && [ ! -e "$d/s" ]; then
  pass "U11: bad key ID"
else
  fail "U11: bad key ID" "the script accepted the key ID or made a file"
fi

exit "$failed"
