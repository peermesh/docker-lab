#!/usr/bin/env bash
# Fail-closed local validation for the repo-tracked production Authentik
# preservation target. This script is intentionally non-mutating: it renders
# docker compose config from a temporary copy with placeholder secrets only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PLAN_ID="PLAN-CORE-RECONCILE-001-REV-AUTHENTIK-PRESERVE"

fail() {
    printf '[validate-vps-production-authentik-overlay] FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf '[validate-vps-production-authentik-overlay] PASS: %s\n' "$*"
}

require_file() {
    local file="$1"
    [[ -f "$file" ]] || fail "missing required file: $file"
}

require_grep() {
    local pattern="$1"
    local file="$2"
    local description="$3"
    grep -Eq -- "$pattern" "$file" || fail "missing ${description} in ${file}"
}

require_absent() {
    local pattern="$1"
    local file="$2"
    local description="$3"
    if grep -Eq -- "$pattern" "$file"; then
        fail "forbidden ${description} found in ${file}"
    fi
}

require_middleware_once() {
    local middleware="$1"
    local count
    count="$(grep -R -h -E "^[[:space:]]{4}${middleware}:" "${CORE_ROOT}/configs/traefik/dynamic"/*.yml | wc -l | tr -d '[:space:]')"
    [[ "$count" == "1" ]] || fail "middleware ${middleware}@file must be defined exactly once, found ${count}"
}

require_file "${CORE_ROOT}/docker-compose.yml"
require_file "${CORE_ROOT}/docker-compose.production.yml"
require_file "${CORE_ROOT}/docker-compose.authentik-production.yml"
require_file "${CORE_ROOT}/authentik-production.env.example"
require_file "${CORE_ROOT}/configs/traefik/dynamic/authentik.yml"
require_file "${CORE_ROOT}/configs/traefik/dynamic/security.yml"
require_file "${CORE_ROOT}/configs/traefik/dynamic/events-rate-limits.yml"
require_file "${CORE_ROOT}/scripts/deploy-vps.sh"
require_file "${CORE_ROOT}/profiles/observability-lite/docker-compose.observability-lite.yml"
require_file "${CORE_ROOT}/profiles/observability-full/docker-compose.observability-full.yml"

overlay="${CORE_ROOT}/docker-compose.authentik-production.yml"
deploy_script="${CORE_ROOT}/scripts/deploy-vps.sh"
env_example="${CORE_ROOT}/authentik-production.env.example"

require_grep '"docker-compose.authentik-production.yml"' "$deploy_script" "active production Authentik compose overlay"
require_absent '"docker-compose.authentik-staging.yml"' "$deploy_script" "staging Authentik overlay in active VPS compose list"
require_grep 'PEERMESH_PRODUCTION_AUTHENTIK_APPLY_APPROVAL' "$deploy_script" "production mutation approval gate"
require_grep "$PLAN_ID" "$deploy_script" "revised plan ID gate"
require_grep '--providers\.file\.directory=/etc/traefik/dynamic' "${CORE_ROOT}/docker-compose.yml" "Traefik split dynamic directory"

for service in authentik-postgres authentik-server authentik-worker; do
    require_grep "^[[:space:]]{2}${service}:" "$overlay" "service ${service}"
done

require_grep 'container_name:[[:space:]]*pmdl_authentik_postgres' "$overlay" "live postgres container name"
require_grep 'container_name:[[:space:]]*pmdl_authentik_server' "$overlay" "live server container name"
require_grep 'container_name:[[:space:]]*pmdl_authentik_worker' "$overlay" "live worker container name"

for secret in authentik_postgres_password authentik_secret_key authentik_bootstrap_token; do
    require_grep "^[[:space:]]{2}${secret}:" "$overlay" "secret ${secret}"
    require_grep "file:[[:space:]]*\\./secrets/${secret}" "$overlay" "secret file ./secrets/${secret}"
done
require_grep './secrets/authentik_bootstrap\.env' "$overlay" "bootstrap env file path"

for volume in pmdl_authentik_postgres_data pmdl_authentik_media pmdl_authentik_templates pmdl_authentik_certs; do
    require_grep "^[[:space:]]{2}${volume}:" "$overlay" "volume ${volume}"
done
require_grep 'name:[[:space:]]*pmdl_authentik-internal' "$overlay" "live Authentik internal network name"

# shellcheck disable=SC2016
require_grep 'traefik\.http\.routers\.authentik\.rule=Host\(`auth\.peers\.social`\)' "$overlay" "auth.peers.social router"
# shellcheck disable=SC2016
require_grep 'traefik\.http\.routers\.authentik-root-outpost\.rule=Host\(`peers\.social`\) && PathPrefix\(`/outpost\.goauthentik\.io`\)' "$overlay" "root outpost router"
# shellcheck disable=SC2016
require_grep 'traefik\.http\.routers\.authentik-admin-outpost\.rule=Host\(`admin-auth\.peers\.social`\) && PathPrefix\(`/outpost\.goauthentik\.io`\)' "$overlay" "admin outpost router"
require_absent 'AUTHENTIK_(POSTGRESQL__PASSWORD|SECRET_KEY|BOOTSTRAP_TOKEN):' "$overlay" "inlined Authentik secret environment value"

for key in AUTHENTIK_POSTGRESQL__PASSWORD AUTHENTIK_SECRET_KEY AUTHENTIK_BOOTSTRAP_TOKEN; do
    line="$(grep -E "^${key}=" "$env_example" || true)"
    [[ -n "$line" ]] || fail "missing ${key} placeholder in ${env_example}"
    value="${line#*=}"
    [[ "$value" == replace-with-production-* ]] || fail "${key} example value must remain a placeholder"
done

for middleware in security-headers ratelimit-api peermesh-auth peermesh-admin-auth; do
    require_middleware_once "$middleware"
done

events_rate_limit_file="${CORE_ROOT}/configs/traefik/dynamic/events-rate-limits.yml"
for limit in 30 60 120; do
    for suffix in ip actor; do
        require_middleware_once "events-ratelimit-${limit}-per-hour-${suffix}"
    done
    require_middleware_once "events-ratelimit-${limit}-per-hour"
    require_grep "average:[[:space:]]*${limit}$" "$events_rate_limit_file" "Events ${limit}/hour average"
done
require_grep 'requestHeaderName:[[:space:]]*X-Peermesh-Actor-WebID' "$events_rate_limit_file" "Events actor rate-limit source criterion"
[[ "$(grep -Ec 'period:[[:space:]]*1h$' "$events_rate_limit_file")" == "6" ]] || fail "all six Events IP/actor buckets must use period 1h"
[[ "$(grep -Ec 'burst:[[:space:]]*1$' "$events_rate_limit_file")" == "6" ]] || fail "all six Events IP/actor buckets must use conservative burst 1"
require_grep 'peermesh-forward-auth:' "${CORE_ROOT}/configs/traefik/dynamic/authentik.yml" "ordinary forward-auth middleware"
require_grep 'peermesh-admin-forward-auth:' "${CORE_ROOT}/configs/traefik/dynamic/authentik.yml" "admin forward-auth middleware"
require_grep 'address:[[:space:]]*"http://authentik-server:9000/outpost\.goauthentik\.io/auth/traefik"' "${CORE_ROOT}/configs/traefik/dynamic/authentik.yml" "Authentik forward-auth address"

command -v docker >/dev/null 2>&1 || fail "docker is required for local compose rendering"
docker compose version >/dev/null 2>&1 || fail "docker compose is required for local compose rendering"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/peermesh-authentik-overlay.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "${tmp_dir}/configs/traefik/dynamic"
mkdir -p "${tmp_dir}/profiles/observability-lite"
mkdir -p "${tmp_dir}/profiles/observability-full"
mkdir -p "${tmp_dir}/secrets"

cp "${CORE_ROOT}/docker-compose.yml" "${tmp_dir}/docker-compose.yml"
cp "${CORE_ROOT}/docker-compose.production.yml" "${tmp_dir}/docker-compose.production.yml"
cp "${CORE_ROOT}/docker-compose.authentik-production.yml" "${tmp_dir}/docker-compose.authentik-production.yml"
cp "${CORE_ROOT}/configs/traefik/dynamic/"*.yml "${tmp_dir}/configs/traefik/dynamic/"
cp "${CORE_ROOT}/profiles/observability-lite/docker-compose.observability-lite.yml" "${tmp_dir}/profiles/observability-lite/"
cp "${CORE_ROOT}/profiles/observability-full/docker-compose.observability-full.yml" "${tmp_dir}/profiles/observability-full/"

cat > "${tmp_dir}/.env" <<'EOF_ENV'
DOMAIN=peers.social
ADMIN_EMAIL=admin@peers.social
TRAEFIK_DASHBOARD_AUTH=admin:placeholder
GRAFANA_ADMIN_PASSWORD=placeholder-grafana-admin-password
HOSTNAME=pmdl-host
EOF_ENV

for secret in \
    postgres_password \
    mysql_root_password \
    mongodb_root_password \
    redis_password \
    minio_root_user \
    minio_root_password \
    dashboard_username \
    dashboard_password \
    authentik_postgres_password \
    authentik_secret_key \
    authentik_bootstrap_token
do
    printf 'placeholder-%s\n' "$secret" > "${tmp_dir}/secrets/${secret}"
done

cat > "${tmp_dir}/secrets/authentik_bootstrap.env" <<'EOF_BOOTSTRAP'
AUTHENTIK_POSTGRESQL__PASSWORD=placeholder-authentik-postgres-password
AUTHENTIK_SECRET_KEY=placeholder-authentik-secret-key
AUTHENTIK_BOOTSTRAP_TOKEN=placeholder-authentik-bootstrap-token
EOF_BOOTSTRAP

rendered="${tmp_dir}/rendered-compose.yml"
(
    cd "$tmp_dir"
    docker compose \
        --env-file .env \
        --profile postgresql \
        -f docker-compose.yml \
        -f docker-compose.production.yml \
        -f docker-compose.authentik-production.yml \
        -f profiles/observability-lite/docker-compose.observability-lite.yml \
        -f profiles/observability-full/docker-compose.observability-full.yml \
        config > "$rendered"
)

for service in authentik-postgres authentik-server authentik-worker; do
    require_grep "^[[:space:]]{2}${service}:" "$rendered" "rendered service ${service}"
done
for container in pmdl_authentik_postgres pmdl_authentik_server pmdl_authentik_worker; do
    require_grep "container_name:[[:space:]]*${container}" "$rendered" "rendered container ${container}"
done
for volume in pmdl_authentik_postgres_data pmdl_authentik_media pmdl_authentik_templates pmdl_authentik_certs; do
    require_grep "^[[:space:]]{2}${volume}:" "$rendered" "rendered volume ${volume}"
done
for secret in authentik_postgres_password authentik_secret_key authentik_bootstrap_token; do
    require_grep "^[[:space:]]{2}${secret}:" "$rendered" "rendered secret ${secret}"
    require_grep "secrets/${secret}" "$rendered" "rendered secret file ${secret}"
done
require_grep 'name:[[:space:]]*pmdl_authentik-internal' "$rendered" "rendered Authentik internal network"
# shellcheck disable=SC2016
require_grep 'traefik\.http\.routers\.authentik\.rule: Host\(`auth\.peers\.social`\)' "$rendered" "rendered auth router"
# shellcheck disable=SC2016
require_grep 'traefik\.http\.routers\.authentik-root-outpost\.rule: Host\(`peers\.social`\) && PathPrefix\(`/outpost\.goauthentik\.io`\)' "$rendered" "rendered root outpost router"
# shellcheck disable=SC2016
require_grep 'traefik\.http\.routers\.authentik-admin-outpost\.rule: Host\(`admin-auth\.peers\.social`\) && PathPrefix\(`/outpost\.goauthentik\.io`\)' "$rendered" "rendered admin outpost router"
require_grep '--providers\.file\.directory=/etc/traefik/dynamic' "$rendered" "rendered Traefik split dynamic directory"

pass "production Authentik overlay renders with live service/container/volume/secret/router contract"
pass "required live file middlewares are defined exactly once: security-headers, ratelimit-api, peermesh-auth, peermesh-admin-auth"
pass "inert Events gateway candidates define paired IP/actor limits at 30, 60, and 120 requests per hour"
pass "production mutation remains gated by ${PLAN_ID}"
