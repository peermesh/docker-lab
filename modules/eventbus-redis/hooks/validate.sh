#!/usr/bin/env bash
set -euo pipefail

module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$module_dir/module.json" ]]; then
  echo "ERROR: module.json not found" >&2
  exit 3
fi

if command -v jq >/dev/null 2>&1; then
  jq -e '.provides.connections[] | select(.type == "eventbus" and .provider == "redis")' "$module_dir/module.json" >/dev/null
fi

echo "eventbus-redis validation passed"
