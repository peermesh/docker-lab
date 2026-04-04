#!/usr/bin/env bash
# deploy-guard.sh — Pre-flight safety guard for PeerMesh Core docker compose deploys.
#
# Purpose:
#   Enforces safe deploy practices and prevents two known incident classes:
#     1. Dev-port compose (18000) pushed over production 80/443 — use production overlay.
#     2. Orphan containers left behind (e.g. pmdl_catchall whoami) — require --remove-orphans.
#
# Checks performed:
#   1. Production overlay (docker-compose.production.yml) is present.
#   2. --remove-orphans will be used on the `up` command.
#   3. Active profiles are listed explicitly (warns if none).
#   4. TRAEFIK_DASHBOARD_AUTH is set and non-empty in the environment/.env.
#   5. DOMAIN env var is set.
#   6. `docker compose ... config --quiet` validates the merged config.
#
# Usage:
#   # Pre-flight checks only (default)
#   ./scripts/deploy-guard.sh --profile observability-lite
#
#   # Dry run — print the final deploy command without executing
#   ./scripts/deploy-guard.sh --dry-run --profile observability-lite
#
#   # Execute deploy after checks pass
#   ./scripts/deploy-guard.sh --exec --profile observability-lite
#
#   # Multiple profiles
#   ./scripts/deploy-guard.sh --exec --profile observability-lite --profile webhook
#
# Exit codes:
#   0  All checks passed (or deploy succeeded with --exec)
#   1  Generic failure
#   2  Missing required env var
#   3  Missing required flag / bad usage
#   4  docker compose config validation failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="check"          # check | dry-run | exec
PROFILES=()
ENV_FILE="${REPO_ROOT}/.env"
BASE_COMPOSE="${REPO_ROOT}/docker-compose.yml"
PROD_COMPOSE="${REPO_ROOT}/docker-compose.production.yml"

color_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
color_green() { printf '\033[32m%s\033[0m\n' "$*"; }
color_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
color_blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

log_info()  { color_blue   "[INFO]  $*"; }
log_ok()    { color_green  "[OK]    $*"; }
log_warn()  { color_yellow "[WARN]  $*"; }
log_err()   { color_red    "[ERROR] $*" 1>&2; }

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 3
}

# ---- arg parse ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exec)     MODE="exec"; shift ;;
    --dry-run)  MODE="dry-run"; shift ;;
    --profile)  [[ $# -ge 2 ]] || { log_err "--profile requires a value"; exit 3; }
                PROFILES+=("$2"); shift 2 ;;
    --env-file) [[ $# -ge 2 ]] || { log_err "--env-file requires a value"; exit 3; }
                ENV_FILE="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *)          log_err "Unknown argument: $1"; usage ;;
  esac
done

log_info "deploy-guard starting (mode=${MODE})"
log_info "Repo root: ${REPO_ROOT}"

# ---- check: compose files exist ----
if [[ ! -f "${BASE_COMPOSE}" ]]; then
  log_err "Base compose file not found: ${BASE_COMPOSE}"
  exit 1
fi
if [[ ! -f "${PROD_COMPOSE}" ]]; then
  log_err "Production overlay missing: ${PROD_COMPOSE}"
  log_err "Refusing to deploy without the production overlay (prevents dev-port regression)."
  exit 1
fi
log_ok "Production overlay present: ${PROD_COMPOSE}"

# ---- check: env file exists ----
if [[ ! -f "${ENV_FILE}" ]]; then
  log_err "Env file not found: ${ENV_FILE}"
  exit 2
fi
log_ok "Env file: ${ENV_FILE}"

# Load env vars from file for the env-var checks (without exporting secrets to children
# unless we actually exec).
get_env_value() {
  # Usage: get_env_value VAR_NAME
  # Strips quotes and leading/trailing whitespace.
  local key="$1"
  local line value
  line=$(grep -E "^[[:space:]]*${key}=" "${ENV_FILE}" | tail -n1 || true)
  [[ -z "${line}" ]] && { printf ''; return; }
  value="${line#*=}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s' "${value}"
}

DOMAIN_VAL="${DOMAIN:-$(get_env_value DOMAIN)}"
TRAEFIK_AUTH_VAL="${TRAEFIK_DASHBOARD_AUTH:-$(get_env_value TRAEFIK_DASHBOARD_AUTH)}"

if [[ -z "${DOMAIN_VAL}" ]]; then
  log_err "DOMAIN is not set (checked environment and ${ENV_FILE})."
  exit 2
fi
log_ok "DOMAIN set: ${DOMAIN_VAL}"

if [[ -z "${TRAEFIK_AUTH_VAL}" ]]; then
  log_err "TRAEFIK_DASHBOARD_AUTH is not set (checked environment and ${ENV_FILE})."
  log_err "Traefik dashboard must be auth-protected before deploy."
  exit 2
fi
log_ok "TRAEFIK_DASHBOARD_AUTH set (len=${#TRAEFIK_AUTH_VAL})"

# ---- check: profiles explicit ----
if [[ ${#PROFILES[@]} -eq 0 ]]; then
  log_warn "No --profile specified. Deploy will run with default profiles only."
  log_warn "If you intended to deploy observability / webhook / etc., re-run with --profile <name>."
fi

# ---- build docker compose base command ----
COMPOSE_CMD=(docker compose --env-file "${ENV_FILE}" -f "${BASE_COMPOSE}" -f "${PROD_COMPOSE}")
for p in "${PROFILES[@]}"; do
  COMPOSE_CMD+=(--profile "${p}")
done

# ---- check: compose config validates ----
log_info "Validating merged compose config..."
if ! "${COMPOSE_CMD[@]}" config --quiet; then
  log_err "docker compose config validation failed."
  exit 4
fi
log_ok "docker compose config validated."

# ---- build final deploy command ----
DEPLOY_CMD=("${COMPOSE_CMD[@]}" up -d --remove-orphans)

# Self-check: confirm --remove-orphans is in the final command (belt-and-braces).
if ! printf '%s\n' "${DEPLOY_CMD[@]}" | grep -qx -- '--remove-orphans'; then
  log_err "Internal guard violation: --remove-orphans missing from deploy command."
  exit 1
fi
log_ok "--remove-orphans present in deploy command."

# Self-check: confirm production overlay is in the final command.
if ! printf '%s\n' "${DEPLOY_CMD[@]}" | grep -qx -- "${PROD_COMPOSE}"; then
  log_err "Internal guard violation: production overlay missing from deploy command."
  exit 1
fi
log_ok "Production overlay present in deploy command."

printf '\n'
log_info "Final deploy command:"
printf '  '
printf '%q ' "${DEPLOY_CMD[@]}"
printf '\n\n'

case "${MODE}" in
  check)
    log_ok "Pre-flight checks passed. Re-run with --dry-run to preview or --exec to deploy."
    exit 0
    ;;
  dry-run)
    log_ok "Dry run complete. No changes made."
    exit 0
    ;;
  exec)
    log_info "Executing deploy..."
    "${DEPLOY_CMD[@]}"
    log_ok "Deploy command finished."
    exit 0
    ;;
esac
