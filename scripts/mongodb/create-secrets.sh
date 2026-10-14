#!/usr/bin/env bash
# 최초 공급 전용. 기존 데이터의 계정·키 변경에는 별도 절차가 필요하다.
set +x
set -euo pipefail
umask 077
export LC_ALL=C

if [[ $# -ne 2 || -z "$1" ]]; then
  printf 'Usage: bash %s <kubernetes-context> <cluster-domain>\n' "$0" >&2
  exit 1
fi
context="$1"
cluster_domain="$2"
if [[ ${#cluster_domain} -gt 253 || ! "$cluster_domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ || "$cluster_domain" == *..* ]]; then
  printf '%s\n' 'Invalid cluster domain; use the domain confirmed in CoreDNS.' >&2
  exit 1
fi
IFS=. read -r -a domain_labels <<< "$cluster_domain"
for label in "${domain_labels[@]}"; do
  if [[ ${#label} -gt 63 || ! "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    printf '%s\n' 'Invalid cluster domain label.' >&2
    exit 1
  fi
done
namespace=dangcharge
root_username=mongodb_admin
app_username=dangcharge_consumer
database=dangcharge
kubectl_args=(--context="$context" --namespace="$namespace")
kubectl "${kubectl_args[@]}" get namespace "$namespace" -o name
existing="$(kubectl "${kubectl_args[@]}" get secret mongodb-root mongodb-app mongodb-keyfile --ignore-not-found -o name)"
claims="$(kubectl "${kubectl_args[@]}" get pvc datadir-mongodb-0 datadir-mongodb-1 datadir-mongodb-2 --ignore-not-found -o name)"
if [[ -n "$existing" || -n "$claims" ]]; then
  printf '%s\n' 'Existing Secrets or PVCs found. Inspect initialization first; credentials will not be overwritten.' >&2
  exit 1
fi
printf 'Target context: %s, namespace: %s, domain: %s\n' "$context" "$namespace" "$cluster_domain"
printf 'Database: %s, application user: %s, administrator: %s\n' "$database" "$app_username" "$root_username"
IFS= read -r -s -p 'Root password (32+ characters, letters/digits/_/-): ' root_password
printf '\n'
IFS= read -r -s -p 'Application password (32+ characters, letters/digits/_/-): ' app_password
printf '\n'
if [[ ! "$root_password" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{31,}$ || ! "$app_password" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{31,}$ || "$root_password" == "$app_password" ]]; then
  printf '%s\n' 'Use different passwords of 32+ characters, starting with a letter/digit and containing only letters/digits/_/-.' >&2
  exit 1
fi

# 임시 파일로 전달해 암호가 명령 인수나 셸 기록에 남지 않게 한다.
secret_dir="$(mktemp -d "${TMPDIR:-/tmp}/dangcharge-mongodb-secrets.XXXXXX")"
trap 'rm -rf -- "$secret_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s' "$root_username" > "$secret_dir/root-username"
printf '%s' "$root_password" > "$secret_dir/root-password"
printf '%s' "$app_username" > "$secret_dir/app-username"
printf '%s' "$app_password" > "$secret_dir/app-password"
printf '%s' "$database" > "$secret_dir/database"
openssl rand -base64 756 | tr -d '\r\n' > "$secret_dir/keyfile"
hosts="mongodb-0.mongodb-headless.$namespace.svc.$cluster_domain:27017,mongodb-1.mongodb-headless.$namespace.svc.$cluster_domain:27017,mongodb-2.mongodb-headless.$namespace.svc.$cluster_domain:27017"
printf 'mongodb://%s:%s@%s/%s?replicaSet=rs0&authSource=%s' "$app_username" "$app_password" "$hosts" "$database" "$database" > "$secret_dir/uri"
unset root_password app_password

kubectl "${kubectl_args[@]}" create secret generic mongodb-root \
  --from-file="MONGO_INITDB_ROOT_USERNAME=$secret_dir/root-username" \
  --from-file="MONGO_INITDB_ROOT_PASSWORD=$secret_dir/root-password"
kubectl "${kubectl_args[@]}" create secret generic mongodb-app \
  --from-file="MONGO_APP_USERNAME=$secret_dir/app-username" \
  --from-file="MONGO_APP_PASSWORD=$secret_dir/app-password" \
  --from-file="MONGO_APP_DATABASE=$secret_dir/database" \
  --from-file="MONGODB_URI=$secret_dir/uri"
kubectl "${kubectl_args[@]}" create secret generic mongodb-keyfile \
  --from-file="keyfile=$secret_dir/keyfile"
printf '%s\n' 'Initial Secrets created. Keep passwords in a password manager. Business collections are managed by the application.'
