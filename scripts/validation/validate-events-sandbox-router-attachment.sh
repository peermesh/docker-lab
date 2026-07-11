#!/usr/bin/env bash
set -euo pipefail

# Description: Render and exercise the local Events service/router attachment.
# Usage: ./scripts/validation/validate-events-sandbox-router-attachment.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
CORE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly CORE_ROOT
readonly COMPOSE_FILE="${CORE_ROOT}/docker-compose.events-sandbox.yml"
readonly PROJECT_NAME="peermesh-events-sandbox-proof"
readonly HOST="${EVENTS_SANDBOX_HOST:-events.localhost}"
readonly PORT="${EVENTS_SANDBOX_PORT:-18080}"
readonly API_PORT="${EVENTS_SANDBOX_API_PORT:-18081}"
readonly BASE_URL="http://127.0.0.1:${PORT}"
readonly API_URL="http://127.0.0.1:${API_PORT}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/peermesh-events-sandbox.XXXXXX")"

cleanup() {
  local exit_code=$?
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --remove-orphans --volumes >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
  exit "$exit_code"
}
trap cleanup EXIT

fail() {
  printf '[validate-events-sandbox] FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '[validate-events-sandbox] PASS: %s\n' "$*"
}

request() {
  local client="$1"
  local actor="$2"
  local path="$3"
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" exec -T "$client" \
    node - "$actor" "$path" <<'JS'
const actor = process.argv[2];
const path = process.argv[3];
fetch(`http://events.localhost${path}`, {
  headers: {
    'X-Sandbox-Actor': actor,
    'X-Peermesh-Actor-WebID': 'https://attacker.example.invalid/spoofed',
  },
}).then(async (response) => {
  await response.text();
  process.stdout.write(`${response.status}|${response.headers.get('retry-after') ?? ''}`);
}).catch((error) => {
  console.error(error);
  process.exit(1);
});
JS
}

for command in docker curl python3; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: ${command}"
done

docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config > "${tmp_dir}/rendered.yml"
for expected in \
  'peermesh-auth@file,events-ratelimit-30-per-hour@file' \
  'peermesh-auth@file,events-ratelimit-60-per-hour@file' \
  'peermesh-auth@file,events-ratelimit-120-per-hour@file'; do
  grep -Fq "$expected" "${tmp_dir}/rendered.yml" || fail "missing auth-before-limit chain: ${expected}"
done
if grep -Eq 'routers\..*(maintenance|cleanup)|Path.*maintenance/cleanup' "${tmp_dir}/rendered.yml"; then
  fail 'maintenance cleanup must not have a public router'
fi
if grep -Eq 'routers\..*public|Path.*api/public' "${tmp_dir}/rendered.yml"; then
  fail 'public venue discovery must remain unrouted pending a security decision'
fi
pass 'rendered route classes use auth-before-limit order and exclude cleanup/public discovery'

docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up --build --detach

for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --header "Host: ${HOST}" "${BASE_URL}/api/events/health" > "${tmp_dir}/health.json"; then
    break
  fi
  if [[ "$attempt" == 30 ]]; then
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" logs >&2
    fail 'Events readiness did not become healthy through Traefik'
  fi
  sleep 1
done

python3 - "${tmp_dir}/health.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as source:
    payload = json.load(source)
if payload != {'ok': True, 'module': 'pm-module-events'}:
    raise SystemExit(f'unexpected health payload: {payload!r}')
PY
pass 'Events readiness returns the exact 200 health contract through Traefik'

curl --fail --silent --show-error "${API_URL}/api/http/routers" > "${tmp_dir}/routers.json"
python3 - "${tmp_dir}/routers.json" <<'PY'
import json
import sys

expected = {
    'events-sandbox-health@docker': ([], ('/api/events/health',)),
    'events-sandbox-write-30@docker': (
        ['peermesh-auth@file', 'events-ratelimit-30-per-hour@file'],
        ('/api/events`', 'submit|withdraw', 'Method(`PATCH`)', 'Method(`DELETE`)'),
    ),
    'events-sandbox-write-60@docker': (
        ['peermesh-auth@file', 'events-ratelimit-60-per-hour@file'],
        ('/rsvps', '/api/admin/events/', 'review|approve|reject|request-revision'),
    ),
    'events-sandbox-read-120@docker': (
        ['peermesh-auth@file', 'events-ratelimit-120-per-hour@file'],
        ('PathPrefix(`/api/events`)', '/api/admin/events/queue', '/attendance/check-in'),
    ),
}
with open(sys.argv[1], encoding='utf-8') as source:
    routers = {router['name']: router for router in json.load(source)}
for name, (middlewares, rule_fragments) in expected.items():
    router = routers.get(name)
    if router is None:
        raise SystemExit(f'missing runtime router: {name}')
    if router.get('status') != 'enabled':
        raise SystemExit(f'router is not enabled: {name}: {router.get("status")!r}')
    if router.get('middlewares', []) != middlewares:
        raise SystemExit(f'wrong middleware order for {name}: {router.get("middlewares", [])!r}')
    rule = router.get('rule', '')
    missing = [fragment for fragment in rule_fragments if fragment not in rule]
    if missing:
        raise SystemExit(f'route class {name} is missing rule fragments: {missing!r}; rule={rule!r}')
PY
pass 'runtime router inventory exposes health plus the exact 30/60/120 classes'

alpha_first="$(request sandbox-client-a alpha /api/events)"
[[ "$alpha_first" == '200|' ]] || fail "expected first actor request 200, got ${alpha_first}"
alpha_repeat="$(request sandbox-client-b alpha /api/events)"
[[ "$alpha_repeat" =~ ^429\|[0-9]+$ ]] || fail "expected repeated actor on a new IP to reach 429 with Retry-After, got ${alpha_repeat}"
beta_first="$(request sandbox-client-c beta /api/events)"
[[ "$beta_first" == '200|' ]] || fail "expected independent actor request 200, got ${beta_first}"
pass 'spoofed actor is stripped, trusted actor is installed, actors have independent buckets, and actor repeat returns 429 with Retry-After'

gamma_first="$(request sandbox-client-d gamma /api/events)"
[[ "$gamma_first" == '200|' ]] || fail "expected first client-IP request 200, got ${gamma_first}"
delta_same_ip="$(request sandbox-client-d delta /api/events)"
[[ "$delta_same_ip" =~ ^429\|[0-9]+$ ]] || fail "expected a new actor on the same client IP to reach 429 with Retry-After, got ${delta_same_ip}"
pass 'sandbox trusted-forwarded client IP drives an independent IP bucket with Retry-After'

cleanup_status="$(curl --silent --show-error --output "${tmp_dir}/cleanup.body" --header "Host: ${HOST}" --request POST "${BASE_URL}/api/maintenance/cleanup" --write-out '%{http_code}')"
[[ "$cleanup_status" == 403 || "$cleanup_status" == 404 ]] || fail "cleanup route must be absent/denied at ingress, got ${cleanup_status}"
public_status="$(curl --silent --show-error --output "${tmp_dir}/public.body" --header "Host: ${HOST}" "${BASE_URL}/api/public/venues/example/events" --write-out '%{http_code}')"
[[ "$public_status" == 403 || "$public_status" == 404 ]] || fail "public venue discovery must remain absent/denied at ingress, got ${public_status}"
pass 'maintenance cleanup and unresolved public venue discovery have no sandbox ingress router and are caught by deny-all'

pass 'Events sandbox service/router attachment proof completed'
