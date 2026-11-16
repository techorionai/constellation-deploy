#!/bin/sh
# Password rules for the scripts in this folder. Other scripts source this file.
# A function prints the name of the variable and never the value.

MIN_PASSWORD_LENGTH=12

# Arguments: variable name, value. Reject an empty value, the placeholder "change-me",
# and a value with fewer than MIN_PASSWORD_LENGTH characters.
check_password() {
  case "$2" in
    '')
      echo "ERROR: $1 is not set" >&2
      return 1
      ;;
    *change-me*)
      echo "ERROR: $1 has the placeholder value change-me. Set a new password." >&2
      return 1
      ;;
  esac
  if [ "${#2}" -lt "$MIN_PASSWORD_LENGTH" ]; then
    echo "ERROR: $1 is too short. The minimum length is $MIN_PASSWORD_LENGTH characters." >&2
    return 1
  fi
}

# Arguments: variable name, value. A Valkey password cannot have white space.
check_no_whitespace() {
  case "$2" in
    *[[:space:]]*)
      echo "ERROR: $1 has white space. A Valkey password cannot have white space." >&2
      return 1
      ;;
  esac
}
