#!/usr/bin/env bats
# Unit tests: connection resolver provider registration

load '../helpers/common'

RESOLVER_SCRIPT=""
MODULE_FIXTURE_DIR=""

setup() {
  setup_test_tmp
  RESOLVER_SCRIPT="${DOCKER_LAB_ROOT}/foundation/lib/connection-resolve.sh"
  MODULE_FIXTURE_DIR="${TEST_TMP_DIR}/modules"
  mkdir -p "$MODULE_FIXTURE_DIR"
}

teardown() {
  teardown_test_tmp
}

write_manifest() {
  local module_id="$1"
  local body="$2"
  local module_dir="${MODULE_FIXTURE_DIR}/${module_id}"

  mkdir -p "$module_dir"
  printf '%s\n' "$body" > "${module_dir}/module.json"
}

@test "connection resolver: eventbus redis provider satisfies eventbus requirement" {
  write_manifest "eventbus-redis" '{
    "id": "eventbus-redis",
    "version": "1.0.0",
    "provides": {
      "connections": [
        {"type": "eventbus", "provider": "redis"}
      ]
    }
  }'

  write_manifest "consumer" '{
    "id": "consumer",
    "version": "1.0.0",
    "requires": {
      "connections": [
        {"type": "eventbus", "providers": ["redis"], "required": true, "alias": "payments-events"}
      ]
    }
  }'

  run env MODULES_DIR="$MODULE_FIXTURE_DIR" "$RESOLVER_SCRIPT" "consumer" --json
  assert_success
  assert_output --partial '"success": true'
  assert_output --partial '"providerModule": "eventbus-redis"'
  assert_output --partial '"providerName": "redis"'
  assert_output --partial '"type": "eventbus"'
}

@test "connection resolver: provider type must match requirement type" {
  write_manifest "cache-redis" '{
    "id": "cache-redis",
    "version": "1.0.0",
    "provides": {
      "connections": [
        {"type": "cache", "provider": "redis"}
      ]
    }
  }'

  write_manifest "consumer" '{
    "id": "consumer",
    "version": "1.0.0",
    "requires": {
      "connections": [
        {"type": "eventbus", "providers": ["redis"], "required": true}
      ]
    }
  }'

  run env MODULES_DIR="$MODULE_FIXTURE_DIR" "$RESOLVER_SCRIPT" "consumer" --json
  assert_failure
  assert_output --partial '"success": false'
  assert_output --partial '"reason": "No matching provider installed"'
}
