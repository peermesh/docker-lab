#!/usr/bin/env bash
set -euo pipefail

redis_host="${EVENTBUS_REDIS_HOST:-redis}"
redis_port="${EVENTBUS_REDIS_PORT:-6379}"

if command -v redis-cli >/dev/null 2>&1; then
  if [[ -n "${REDIS_PASSWORD:-}" ]]; then
    if redis-cli -h "$redis_host" -p "$redis_port" -a "$REDIS_PASSWORD" ping >/dev/null 2>&1; then
      printf '{"status":"healthy","checks":[{"name":"redis","status":"pass"}]}\n'
      exit 0
    fi
  else
    if redis-cli -h "$redis_host" -p "$redis_port" ping >/dev/null 2>&1; then
      printf '{"status":"healthy","checks":[{"name":"redis","status":"pass"}]}\n'
      exit 0
    fi
  fi
  printf '{"status":"degraded","checks":[{"name":"redis","status":"warn","message":"redis-cli could not reach Redis"}]}\n'
  exit 2
fi

printf '{"status":"degraded","checks":[{"name":"redis-cli","status":"warn","message":"redis-cli unavailable; provider registration only"}]}\n'
exit 2
