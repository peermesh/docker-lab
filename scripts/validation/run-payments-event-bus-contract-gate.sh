#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core_root="$(cd "$script_dir/../.." && pwd)"

cd "$core_root"

echo "[payments-event-bus-contract-gate] checking Payments event bus registry"
python3 scripts/validation/validate_payments_event_bus_contract.py --simulate
echo "[payments-event-bus-contract-gate] success"
