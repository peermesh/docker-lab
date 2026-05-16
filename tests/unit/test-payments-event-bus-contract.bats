#!/usr/bin/env bats
# Unit tests: Payments event bus registry and delivery contract

load '../helpers/common'

@test "payments event bus contract validates canonical registry and fanout simulation" {
  run "${DOCKER_LAB_ROOT}/scripts/validation/run-payments-event-bus-contract-gate.sh"
  assert_success
  assert_output --partial "[payments-event-bus-contract] ok: checked 26 canonical Payments events"
  assert_output --partial '"email-payments"'
  assert_output --partial '"pm-module-payments.dlq.payment.intake.succeeded": 1'
}
