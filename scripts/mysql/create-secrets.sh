#!/usr/bin/env bash
# 최초 공급 전용. 기존 DB 계정의 비밀번호 변경에는 별도 rotation 절차가 필요하다.
set +x
set -euo pipefail
umask 077

if [[ $# -ne 1 || -z "$1" ]]; then
  printf 'Usage: bash %s <kubernetes-context>\n' "$0" >&2
  exit 1
fi

context="$1"
namespace=dangcharge
kubectl_args=(--context="$context" --namespace="$namespace")

kubectl "${kubectl_args[@]}" get namespace "$namespace" -o name
existing_secrets="$(kubectl "${kubectl_args[@]}" get secret mysql-root mysql-app --ignore-not-found -o name)"
if [[ -n "$existing_secrets" ]]; then
  printf '%s\n' 'Secret already exists. Inspect existing initialization; this script does not overwrite credentials.' >&2
  exit 1
fi

printf 'Target context: %s, namespace: %s\n' "$context" "$namespace"
read -r -p 'Database name: ' database
read -r -p 'Application username: ' app_username
if [[ ! "$database" =~ ^[a-z][a-z0-9_]{0,63}$ || ! "$app_username" =~ ^[a-z][a-z0-9_]{0,31}$ ]]; then
  printf '%s\n' 'Use a lowercase letter first, then lowercase letters, digits or underscores. DB: max 64; user: max 32.' >&2
  exit 1
fi
case "$database" in
  mysql|information_schema|performance_schema|sys)
    printf '%s\n' 'System database names are not allowed.' >&2
    exit 1
    ;;
esac
if [[ "$app_username" == root ]]; then
  printf '%s\n' 'The application must use a separate account.' >&2
  exit 1
fi

IFS= read -r -s -p 'Root password (32+ characters): ' root_password
printf '\n'
IFS= read -r -s -p 'Application password (32+ characters): ' app_password
printf '\n'
if [[ ${#root_password} -lt 32 || ${#app_password} -lt 32 || "$root_password" == "$app_password" ]]; then
  printf '%s\n' 'Use different root/application passwords of at least 32 characters.' >&2
  exit 1
fi

# --from-file keeps passwords out of command arguments and shell history.
secret_dir="$(mktemp -d "${TMPDIR:-/tmp}/dangcharge-mysql-secrets.XXXXXX")"
trap 'rm -rf -- "$secret_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s' "$root_password" > "$secret_dir/root-password"
printf '%s' "$app_password" > "$secret_dir/app-password"
printf '%s' "$database" > "$secret_dir/database"
printf '%s' "$app_username" > "$secret_dir/username"
unset root_password app_password

kubectl "${kubectl_args[@]}" create secret generic mysql-root \
  --from-file="MYSQL_ROOT_PASSWORD=$secret_dir/root-password"
kubectl "${kubectl_args[@]}" create secret generic mysql-app \
  --from-file="MYSQL_DATABASE=$secret_dir/database" \
  --from-file="MYSQL_USER=$secret_dir/username" \
  --from-file="MYSQL_PASSWORD=$secret_dir/app-password"

printf '%s\n' 'Initial Secrets created. Keep credentials in a password manager; schema provisioning is still pending.'
