#!/usr/bin/env bash
# Negative cases of scripts/check-compose.sh.
#
# Each case is a folder in tests/fixtures/check-compose/. The folder has the files that
# the check reads (compose.yaml, .env.example, .gitignore) with one defect, and a file
# expect.txt. The script copies the case to a temporary folder outside the repository and
# runs the check on the copy. The case passes if:
#   - expect.txt is "PASS" and the exit code is 0, or
#   - the exit code is 1 and the output has each line of expect.txt.
#
# The case "script-crlf" has no shell file in Git. The script writes one with CRLF line
# endings into the temporary copy. A CRLF shell file in Git would stop the shell lint.
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cases_dir="$repo_root/tests/fixtures/check-compose"
failed=0
tmp=""

cleanup() {
  if [ -n "$tmp" ]; then
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT

for case_dir in "$cases_dir"/*/; do
  name="$(basename "$case_dir")"
  tmp="$(mktemp -d)"
  cp -R "$case_dir". "$tmp"/
  if [ "$name" = "script-crlf" ]; then
    printf '#!/bin/sh\r\necho ok\r\n' > "$tmp/script.sh"
  fi
  output="$(bash "$repo_root/scripts/check-compose.sh" "$tmp" 2>&1)"
  code=$?
  expect="$(cat "$case_dir/expect.txt")"
  if [ "$expect" = "PASS" ]; then
    if [ "$code" -eq 0 ]; then
      echo "ok: $name"
    else
      echo "FAIL: $name: expected exit code 0, got $code"
      echo "$output"
      failed=1
    fi
  else
    if [ "$code" -eq 1 ] && printf '%s\n' "$output" | grep -qF -f "$case_dir/expect.txt"; then
      echo "ok: $name"
    else
      echo "FAIL: $name: expected exit code 1 and the text of expect.txt, got $code"
      echo "$output"
      failed=1
    fi
  fi
  rm -rf "$tmp"
  tmp=""
done

# Git has no shell file with a CR character.
while IFS= read -r -d '' file; do
  content="$(cat "$repo_root/$file")"
  if [[ "$content" == *$'\r'* ]]; then
    echo "FAIL: tracked shell file has a CR character: $file"
    failed=1
  fi
done < <(cd "$repo_root" && git ls-files -z '*.sh')

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-compose-cases: all cases passed"
